/* Windows implementation of host/platform.h: a VT-mode console (Windows 10
 * 1809 or later, Windows Terminal, conhost or any ConPTY client) with raw key
 * input read as console input records, QueryPerformanceCounter frame pacing,
 * console control and crash handlers that restore the console, and in-process
 * waveOut audio fed from an AudioRing on a device-event thread. */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include "audio_ring.h"
#include "platform.h"
#include <direct.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#include <stdlib.h>
#include <string.h>

#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif
#ifndef DISABLE_NEWLINE_AUTO_RETURN
#define DISABLE_NEWLINE_AUTO_RETURN 0x0008
#endif
#ifndef ENABLE_VIRTUAL_TERMINAL_INPUT
#define ENABLE_VIRTUAL_TERMINAL_INPUT 0x0200
#endif

/* waveOut: three 512-sample buffers (about 23 ms each at 22050 Hz) in
   flight, and at most RING_KEEP more samples waiting in the ring. */
enum { WAVE_BUFFERS = 3, WAVE_SAMPLES = 512, RING_CAPACITY = 4096, RING_KEEP = 1024 };

static struct {
	HANDLE in, out;
	DWORD saved_in_mode, saved_out_mode;
	UINT saved_in_cp, saved_out_cp;
	volatile LONG raw;
	const char *leave;
	size_t leave_length;
	int cols, rows; /* last size seen, to notice window resizes */
	WCHAR high_surrogate;
	LARGE_INTEGER frequency;
	/* audio */
	HWAVEOUT wave;
	WAVEHDR headers[WAVE_BUFFERS];
	int16_t buffers[WAVE_BUFFERS][WAVE_SAMPLES];
	CRITICAL_SECTION lock;
	AudioRing ring;
	int16_t ring_storage[RING_CAPACITY];
	HANDLE done_event, thread;
	volatile LONG audio_running;
} ws = {.in = INVALID_HANDLE_VALUE, .out = INVALID_HANDLE_VALUE};

static volatile LONG quit_requested;
static volatile LONG resized = 1;
static volatile LONG stop_requested;

void plat_init(void) {
	/* Frame dumps, logs and PCM go out byte for byte. */
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
	QueryPerformanceFrequency(&ws.frequency);
	ws.out = GetStdHandle(STD_OUTPUT_HANDLE);
}

const char *plat_os_name(void) { return "windows"; }
long plat_pid(void) { return (long)_getpid(); }
bool plat_console_truecolor(void) { return true; }

/* ---------- terminal ---------- */

bool plat_stdout_is_terminal(void) {
	DWORD mode;
	return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
}

int plat_term_open_input(void) {
	DWORD mode;
	ws.in = GetStdHandle(STD_INPUT_HANDLE);
	if (ws.in != INVALID_HANDLE_VALUE && GetConsoleMode(ws.in, &mode)) return 0;
	ws.in = CreateFileA("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
	return ws.in == INVALID_HANDLE_VALUE || !GetConsoleMode(ws.in, &mode) ? -1 : 0;
}

void plat_term_write(const void *bytes, size_t length) {
	const char *p = bytes;
	while (length) {
		DWORD chunk = length > 1u << 20 ? 1u << 20 : (DWORD)length, wrote = 0;
		if (!WriteFile(ws.out, p, chunk, &wrote, NULL) || !wrote) return;
		p += wrote;
		length -= wrote;
	}
}

void plat_term_restore(void) {
	if (!InterlockedExchange(&ws.raw, 0)) return;
	if (ws.leave) plat_term_write(ws.leave, ws.leave_length);
	SetConsoleMode(ws.in, ws.saved_in_mode);
	SetConsoleMode(ws.out, ws.saved_out_mode);
	SetConsoleCP(ws.saved_in_cp);
	SetConsoleOutputCP(ws.saved_out_cp);
	timeEndPeriod(1);
}

int plat_term_enter(const char *enter, size_t enter_length) {
	if (!GetConsoleMode(ws.in, &ws.saved_in_mode) || !GetConsoleMode(ws.out, &ws.saved_out_mode)) {
		errno = ENOTTY;
		return -1;
	}
	ws.saved_in_cp = GetConsoleCP();
	ws.saved_out_cp = GetConsoleOutputCP();
	DWORD out_mode = ws.saved_out_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
	if (!SetConsoleMode(ws.out, out_mode)) {
		/* Consoles older than Windows 10 1809 have no VT processing. */
		errno = ENOTSUP;
		return -1;
	}
	/* No line editing, echo or Ctrl-C processing (Ctrl-C arrives as 0x03, as
	   in a raw POSIX terminal); keys as VT sequences; resize events; and
	   ENABLE_EXTENDED_FLAGS without quick-edit so a stray click cannot
	   freeze the game by starting a selection. */
	SetConsoleMode(ws.in, ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS);
	SetConsoleCP(CP_UTF8);
	SetConsoleOutputCP(CP_UTF8);
	timeBeginPeriod(1);
	InterlockedExchange(&ws.raw, 1);
	plat_term_size(&ws.cols, &ws.rows);
	plat_term_write(enter, enter_length);
	return 0;
}

void plat_term_size(int *cols, int *rows) {
	CONSOLE_SCREEN_BUFFER_INFO info;
	if (GetConsoleScreenBufferInfo(ws.out, &info)) {
		*cols = info.srWindow.Right - info.srWindow.Left + 1;
		*rows = info.srWindow.Bottom - info.srWindow.Top + 1;
	} else {
		*cols = 80;
		*rows = 24;
	}
}

/* One UTF-16 code unit from a key event, as UTF-8 (pairing surrogates). */
static size_t utf8_from_utf16(WCHAR c, uint8_t out[4]) {
	uint32_t cp;
	if (c >= 0xD800 && c < 0xDC00) {
		ws.high_surrogate = c;
		return 0;
	}
	if (c >= 0xDC00 && c < 0xE000) {
		if (!ws.high_surrogate) return 0;
		cp = 0x10000 + (((uint32_t)ws.high_surrogate - 0xD800) << 10) + ((uint32_t)c - 0xDC00);
		ws.high_surrogate = 0;
	} else {
		cp = c;
	}
	if (cp < 0x80) {
		out[0] = (uint8_t)cp;
		return 1;
	}
	if (cp < 0x800) {
		out[0] = (uint8_t)(0xC0 | (cp >> 6));
		out[1] = (uint8_t)(0x80 | (cp & 0x3F));
		return 2;
	}
	if (cp < 0x10000) {
		out[0] = (uint8_t)(0xE0 | (cp >> 12));
		out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
		out[2] = (uint8_t)(0x80 | (cp & 0x3F));
		return 3;
	}
	out[0] = (uint8_t)(0xF0 | (cp >> 18));
	out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
	out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
	out[3] = (uint8_t)(0x80 | (cp & 0x3F));
	return 4;
}

size_t plat_term_read(uint8_t *buf, size_t capacity) {
	size_t n = 0;
	/* Window resizes do not always produce buffer-size events; compare. */
	int cols, rows;
	plat_term_size(&cols, &rows);
	if (cols != ws.cols || rows != ws.rows) {
		ws.cols = cols;
		ws.rows = rows;
		InterlockedExchange(&resized, 1);
	}
	for (;;) {
		DWORD pending = 0;
		if (!GetNumberOfConsoleInputEvents(ws.in, &pending) || !pending) break;
		INPUT_RECORD records[64];
		DWORD got = 0;
		if (!ReadConsoleInputW(ws.in, records, pending < 64 ? pending : 64, &got) || !got) break;
		for (DWORD i = 0; i < got; i++) {
			if (records[i].EventType == WINDOW_BUFFER_SIZE_EVENT) {
				InterlockedExchange(&resized, 1);
				continue;
			}
			if (records[i].EventType != KEY_EVENT) continue;
			KEY_EVENT_RECORD *k = &records[i].Event.KeyEvent;
			if (!k->bKeyDown || !k->uChar.UnicodeChar) continue;
			uint8_t utf8[4];
			size_t len = utf8_from_utf16(k->uChar.UnicodeChar, utf8);
			for (WORD r = 0; r < (k->wRepeatCount ? k->wRepeatCount : 1); r++) {
				if (n + len > capacity) return n;
				memcpy(buf + n, utf8, len);
				n += len;
			}
		}
	}
	return n;
}

/* ---------- notifications ---------- */

static BOOL WINAPI on_console_control(DWORD type) {
	InterlockedExchange(&quit_requested, 1);
	/* Windows ends the process soon after a close, logoff or shutdown
	   handler returns, so put the console back now. */
	if (type == CTRL_CLOSE_EVENT || type == CTRL_LOGOFF_EVENT || type == CTRL_SHUTDOWN_EVENT) plat_term_restore();
	return TRUE;
}

static LONG WINAPI on_crash(EXCEPTION_POINTERS *info) {
	(void)info;
	plat_term_restore();
	return EXCEPTION_CONTINUE_SEARCH;
}

void plat_install_handlers(const char *leave, size_t leave_length) {
	ws.leave = leave;
	ws.leave_length = leave_length;
	SetConsoleCtrlHandler(on_console_control, TRUE);
	SetUnhandledExceptionFilter(on_crash);
}

bool plat_quit_requested(void) { return quit_requested != 0; }
bool plat_take_resized(void) { return InterlockedExchange(&resized, 0) != 0; }
void plat_mark_resized(void) { InterlockedExchange(&resized, 1); }
void plat_request_suspend(void) { InterlockedExchange(&stop_requested, 1); }
bool plat_take_suspend(void) { return InterlockedExchange(&stop_requested, 0) != 0; }

/* Windows consoles have no job control; a suspend request is ignored. */
void plat_suspend(const char *enter, size_t enter_length) {
	(void)enter;
	(void)enter_length;
}

/* ---------- clock ---------- */

uint64_t plat_now_us(void) {
	LARGE_INTEGER now;
	QueryPerformanceCounter(&now);
	uint64_t f = (uint64_t)ws.frequency.QuadPart, c = (uint64_t)now.QuadPart;
	return c / f * 1000000u + c % f * 1000000u / f;
}

/* Sleep() has 1 ms resolution once timeBeginPeriod(1) is in effect; sleep
   to within a millisecond, then yield until the deadline. */
void plat_sleep_until_us(uint64_t deadline_us) {
	for (;;) {
		uint64_t now = plat_now_us();
		if (now >= deadline_us || quit_requested) return;
		uint64_t left_ms = (deadline_us - now) / 1000u;
		if (left_ms > 1) Sleep((DWORD)(left_ms - 1));
		else Sleep(0);
	}
}

/* ---------- audio ---------- */

static DWORD WINAPI audio_thread(LPVOID unused) {
	(void)unused;
	while (ws.audio_running) {
		WaitForSingleObject(ws.done_event, 50);
		for (int i = 0; i < WAVE_BUFFERS; i++) {
			WAVEHDR *h = &ws.headers[i];
			if (!(h->dwFlags & WHDR_DONE) || !ws.audio_running) continue;
			EnterCriticalSection(&ws.lock);
			audio_ring_pull(&ws.ring, ws.buffers[i], WAVE_SAMPLES);
			LeaveCriticalSection(&ws.lock);
			waveOutWrite(ws.wave, h, sizeof *h);
		}
	}
	return 0;
}

int plat_audio_open(int rate) {
	WAVEFORMATEX format = {0};
	format.wFormatTag = WAVE_FORMAT_PCM;
	format.nChannels = 1;
	format.nSamplesPerSec = (DWORD)rate;
	format.wBitsPerSample = 16;
	format.nBlockAlign = 2;
	format.nAvgBytesPerSec = (DWORD)rate * 2;
	ws.done_event = CreateEventA(NULL, FALSE, FALSE, NULL);
	if (!ws.done_event) return -1;
	if (waveOutOpen(&ws.wave, WAVE_MAPPER, &format, (DWORD_PTR)ws.done_event, 0, CALLBACK_EVENT) != MMSYSERR_NOERROR) {
		CloseHandle(ws.done_event);
		ws.done_event = NULL;
		return -1;
	}
	InitializeCriticalSection(&ws.lock);
	audio_ring_init(&ws.ring, ws.ring_storage, RING_CAPACITY);
	for (int i = 0; i < WAVE_BUFFERS; i++) {
		WAVEHDR *h = &ws.headers[i];
		memset(h, 0, sizeof *h);
		memset(ws.buffers[i], 0, sizeof ws.buffers[i]);
		h->lpData = (LPSTR)ws.buffers[i];
		h->dwBufferLength = sizeof ws.buffers[i];
		waveOutPrepareHeader(ws.wave, h, sizeof *h);
		waveOutWrite(ws.wave, h, sizeof *h);
	}
	ws.audio_running = 1;
	ws.thread = CreateThread(NULL, 0, audio_thread, NULL, 0, NULL);
	if (!ws.thread) {
		plat_audio_close();
		return -1;
	}
	return 0;
}

void plat_audio_write(const int16_t *samples, size_t count) {
	if (!ws.audio_running) return;
	EnterCriticalSection(&ws.lock);
	audio_ring_push(&ws.ring, samples, count, RING_KEEP);
	LeaveCriticalSection(&ws.lock);
}

bool plat_audio_active(void) { return ws.audio_running != 0; }

void plat_audio_close(void) {
	if (!ws.wave) return;
	InterlockedExchange(&ws.audio_running, 0);
	if (ws.thread) {
		SetEvent(ws.done_event);
		WaitForSingleObject(ws.thread, INFINITE);
		CloseHandle(ws.thread);
		ws.thread = NULL;
	}
	waveOutReset(ws.wave);
	for (int i = 0; i < WAVE_BUFFERS; i++) waveOutUnprepareHeader(ws.wave, &ws.headers[i], sizeof ws.headers[i]);
	waveOutClose(ws.wave);
	ws.wave = NULL;
	CloseHandle(ws.done_event);
	ws.done_event = NULL;
	DeleteCriticalSection(&ws.lock);
}

/* ---------- files ---------- */

char *plat_default_scores_path(void) {
	const char *appdata = getenv("APPDATA");
	if (!appdata || !*appdata) return NULL;
	size_t n = strlen(appdata) + sizeof "\\pinterm\\scores.txt";
	char *path = malloc(n);
	if (path) snprintf(path, n, "%s\\pinterm\\scores.txt", appdata);
	return path;
}

static bool is_directory(const char *path) {
	DWORD attrs = GetFileAttributesA(path);
	return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY);
}

/* Either separator; drive ("C:") and existing components are skipped. */
int plat_make_parents(const char *path) {
	char dir[4096];
	if (snprintf(dir, sizeof dir, "%s", path) >= (int)sizeof dir) return -1;
	for (char *p = dir + 1; *p; p++) {
		if (*p != '/' && *p != '\\') continue;
		char sep = *p;
		*p = '\0';
		if (p[-1] != ':' && _mkdir(dir) != 0 && !is_directory(dir)) return -1;
		*p = sep;
	}
	return 0;
}

int plat_sync_file(FILE *f) { return _commit(_fileno(f)); }

int plat_replace_file(const char *src, const char *dst) {
	if (MoveFileExA(src, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) return 0;
	errno = EACCES;
	return -1;
}
#endif
