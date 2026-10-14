/* Windows implementation of host/platform.h: a VT-mode console (Windows 10
 * 1809 or later, Windows Terminal, conhost or any ConPTY client) with keys read
 * as console input records and reported with releases (see win_keys.h),
 * QueryPerformanceCounter frame pacing, console control and crash handlers
 * that restore the console, and in-process waveOut audio fed from an AudioRing
 * on a device-event thread. */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include "audio_ring.h"
#include "platform.h"
#include "win_keys.h"
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
	WinKeys keys; /* held keys, for kitty-style repeat and release reports */
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
	   in a raw POSIX terminal). Keys are read as raw records and translated by
	   host/win_keys.c, which needs each key's release. Window and focus
	   events on; ENABLE_EXTENDED_FLAGS without quick-edit so a stray click
	   cannot freeze the game by starting a selection. */
	SetConsoleMode(ws.in, ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS);
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

/* A key event's UTF-16 code unit as a code point: surrogate pairs arrive as
   two records, so the high half is held until the low half; 0 for none. */
static uint32_t codepoint_from_utf16(WCHAR c) {
	if (c >= 0xD800 && c < 0xDC00) {
		ws.high_surrogate = c;
		return 0;
	}
	if (c >= 0xDC00 && c < 0xE000) {
		if (!ws.high_surrogate) return 0;
		uint32_t cp = 0x10000 + (((uint32_t)ws.high_surrogate - 0xD800) << 10) + ((uint32_t)c - 0xDC00);
		ws.high_surrogate = 0;
		return cp;
	}
	return c;
}

/* Append bytes if they fit whole; false once the packet is full. */
static bool put(uint8_t *buf, size_t capacity, size_t *n, const uint8_t *bytes, size_t length) {
	if (*n + length > capacity) return false;
	memcpy(buf + *n, bytes, length);
	*n += length;
	return true;
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
		/* Read only what is sure to fit; one key record needs at most
		   WIN_KEYS_MAX_BYTES and focus loss at most a few releases. */
		DWORD room = (DWORD)((capacity - n) / (WIN_KEYS_MAX_BYTES * 4));
		if (!room) break;
		INPUT_RECORD records[64];
		DWORD want = pending < room ? pending : room, got = 0;
		if (want > 64) want = 64;
		if (!ReadConsoleInputW(ws.in, records, want, &got) || !got) break;
		for (DWORD i = 0; i < got; i++) {
			uint8_t bytes[WIN_KEYS_MAX_BYTES * 4];
			size_t len = 0;
			if (records[i].EventType == WINDOW_BUFFER_SIZE_EVENT) {
				InterlockedExchange(&resized, 1);
			} else if (records[i].EventType == FOCUS_EVENT) {
				if (!records[i].Event.FocusEvent.bSetFocus) len = win_keys_focus_lost(&ws.keys, bytes, sizeof bytes);
			} else if (records[i].EventType == KEY_EVENT) {
				KEY_EVENT_RECORD *k = &records[i].Event.KeyEvent;
				WCHAR unit = k->uChar.UnicodeChar;
				if (unit >= 0xD800 && unit < 0xDC00) {
					codepoint_from_utf16(unit); /* wait for the low half */
					continue;
				}
				uint32_t cp = codepoint_from_utf16(unit);
				WORD repeats = k->bKeyDown && k->wRepeatCount > 1 ? k->wRepeatCount : 1;
				for (WORD r = 0; r < repeats && r < 4; r++)
					len += win_key_event(&ws.keys, k->wVirtualKeyCode, k->bKeyDown != 0, cp, bytes + len);
			}
			if (len && !put(buf, capacity, &n, bytes, len)) return n;
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
