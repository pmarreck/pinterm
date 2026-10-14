/* POSIX implementation of host/platform.h (Linux and macOS): termios raw mode
 * with restoration on exit and crash signals, SIGWINCH/SIGTSTP handling,
 * CLOCK_MONOTONIC pacing, and audio through CoreAudio (macOS) or an external
 * player process fed by a nonblocking pipe (pw-play, paplay or aplay). */
#if !defined(_WIN32)
#include "platform.h"
#include "audio_coreaudio.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static struct {
	bool raw;
	struct termios saved;
	int tty_in;
	const char *leave;
	size_t leave_length;
	int audio_fd;
	pid_t audio_pid;
	bool audio_coreaudio; /* audio_fd feeds the in-process CoreAudio queue */
} ps = {.tty_in = -1, .audio_fd = -1, .audio_pid = -1};

static volatile sig_atomic_t quit_requested;
static volatile sig_atomic_t resized = 1;
static volatile sig_atomic_t stop_requested;

void plat_init(void) {}

const char *plat_os_name(void) {
#if defined(__APPLE__)
	return "macos";
#elif defined(__linux__)
	return "linux";
#else
	return "unknown-os";
#endif
}

long plat_pid(void) { return (long)getpid(); }

/* ---------- terminal ---------- */

bool plat_stdout_is_terminal(void) { return isatty(STDOUT_FILENO); }

int plat_term_open_input(void) {
	ps.tty_in = isatty(STDIN_FILENO) ? STDIN_FILENO : open("/dev/tty", O_RDONLY | O_CLOEXEC);
	return ps.tty_in < 0 ? -1 : 0;
}

void plat_term_write(const void *bytes, size_t length) {
	const uint8_t *p = bytes;
	while (length) {
		ssize_t n = write(STDOUT_FILENO, p, length);
		if (n < 0) {
			if (errno == EINTR) continue;
			if (errno == EAGAIN) {
				struct timespec ts = {0, 1000000};
				nanosleep(&ts, NULL);
				continue;
			}
			return;
		}
		p += n;
		length -= (size_t)n;
	}
}

/* Async-signal-safe: only write(2) and tcsetattr(3). */
void plat_term_restore(void) {
	if (!ps.raw) return;
	ps.raw = false;
	if (ps.leave) (void)!write(STDOUT_FILENO, ps.leave, ps.leave_length);
	tcsetattr(ps.tty_in, TCSAFLUSH, &ps.saved);
}

int plat_term_enter(const char *enter, size_t enter_length) {
	if (tcgetattr(ps.tty_in, &ps.saved) != 0) return -1;
	struct termios raw = ps.saved;
	raw.c_iflag &= ~(tcflag_t)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
	raw.c_oflag &= ~(tcflag_t)OPOST;
	raw.c_cflag |= CS8;
	raw.c_lflag &= ~(tcflag_t)(ECHO | ICANON | IEXTEN | ISIG);
	raw.c_cc[VMIN] = 0;
	raw.c_cc[VTIME] = 0;
	if (tcsetattr(ps.tty_in, TCSAFLUSH, &raw) != 0) return -1;
	ps.raw = true;
	plat_term_write(enter, enter_length);
	return 0;
}

void plat_term_size(int *cols, int *rows) {
	struct winsize ws;
	if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col && ws.ws_row) {
		*cols = ws.ws_col;
		*rows = ws.ws_row;
	} else {
		*cols = 80;
		*rows = 24;
	}
}

size_t plat_term_read(uint8_t *buf, size_t capacity) {
	size_t n = 0;
	while (n < capacity) {
		ssize_t r = read(ps.tty_in, buf + n, capacity - n);
		if (r <= 0) break;
		n += (size_t)r;
	}
	return n;
}

/* ---------- notifications ---------- */

static void on_quit_signal(int sig) {
	(void)sig;
	quit_requested = 1;
}
static void on_winch(int sig) {
	(void)sig;
	resized = 1;
}
static void on_tstp(int sig) {
	(void)sig;
	stop_requested = 1;
}
static void on_fatal(int sig) {
	plat_term_restore();
	signal(sig, SIG_DFL);
	raise(sig);
}

void plat_install_handlers(const char *leave, size_t leave_length) {
	ps.leave = leave;
	ps.leave_length = leave_length;
	struct sigaction sa = {0};
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = on_quit_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGQUIT, &sa, NULL);
	sa.sa_handler = on_winch;
	sigaction(SIGWINCH, &sa, NULL);
	sa.sa_handler = on_tstp;
	sigaction(SIGTSTP, &sa, NULL);
	sa.sa_handler = SIG_IGN;
	sigaction(SIGPIPE, &sa, NULL);
	sa.sa_handler = on_fatal;
	sa.sa_flags = (int)SA_RESETHAND;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
	sigaction(SIGFPE, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
}

bool plat_quit_requested(void) { return quit_requested; }

bool plat_take_resized(void) {
	if (!resized) return false;
	resized = 0;
	return true;
}

void plat_mark_resized(void) { resized = 1; }
void plat_request_suspend(void) { stop_requested = 1; }

bool plat_take_suspend(void) {
	if (!stop_requested) return false;
	stop_requested = 0;
	return true;
}

void plat_suspend(const char *enter, size_t enter_length) {
	plat_term_restore();
	plat_audio_close();
	/* SIGSTOP rather than SIGTSTP: POSIX discards default-stop TSTP in
	 * orphaned process groups, which would leave the game un-suspended. */
	raise(SIGSTOP);
	/* Resumed by SIGCONT. */
	if (plat_term_enter(enter, enter_length) != 0) quit_requested = 1;
	resized = 1;
}

/* ---------- clock ---------- */

uint64_t plat_now_us(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint64_t)now.tv_sec * 1000000u + (uint64_t)now.tv_nsec / 1000u;
}

/* Sleep until an absolute CLOCK_MONOTONIC deadline, resuming after signals
   unless a quit was requested. macOS has no clock_nanosleep, so there the
   remaining time is recomputed and slept relatively on each pass. */
void plat_sleep_until_us(uint64_t deadline_us) {
#if defined(TIMER_ABSTIME) && !defined(__APPLE__)
	struct timespec deadline = {(time_t)(deadline_us / 1000000u), (long)(deadline_us % 1000000u) * 1000L};
	while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL) == EINTR && !quit_requested) {}
#else
	for (;;) {
		uint64_t now = plat_now_us();
		if (now >= deadline_us) return;
		uint64_t left_us = deadline_us - now;
		struct timespec left = {(time_t)(left_us / 1000000u), (long)(left_us % 1000000u) * 1000L};
		if (nanosleep(&left, NULL) == 0 || errno != EINTR || quit_requested) return;
	}
#endif
}

/* ---------- audio ---------- */

static bool program_on_path(const char *name) {
	const char *path = getenv("PATH");
	if (!path) return false;
	char buf[4096];
	while (*path) {
		const char *end = strchr(path, ':');
		size_t len = end ? (size_t)(end - path) : strlen(path);
		if (len && len + strlen(name) + 2 < sizeof buf) {
			memcpy(buf, path, len);
			buf[len] = '/';
			strcpy(buf + len + 1, name);
			if (access(buf, X_OK) == 0) return true;
		}
		if (!end) break;
		path = end + 1;
	}
	return false;
}

int plat_audio_open(int rate) {
#if defined(__APPLE__)
	int ca_fds[2];
	if (pipe(ca_fds) == 0) {
		for (int i = 0; i < 2; i++) {
			fcntl(ca_fds[i], F_SETFD, FD_CLOEXEC);
			fcntl(ca_fds[i], F_SETFL, O_NONBLOCK);
		}
		if (coreaudio_start(ca_fds[0], rate) == 0) {
			ps.audio_fd = ca_fds[1];
			ps.audio_coreaudio = true;
			return 0;
		}
		close(ca_fds[0]);
		close(ca_fds[1]);
	}
#endif
	/* The player argument lists name 22050 Hz, the only rate the core uses. */
	(void)rate;
	static char *pw[] = {"pw-play", "--rate=22050", "--channels=1", "--format=s16", "--latency=40ms", "-", NULL};
	static char *pa[] = {"paplay", "--raw", "--rate=22050", "--channels=1", "--format=s16le", "--latency-msec=40", NULL};
	static char *al[] = {"aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", "22050", "-c", "1", "--buffer-time=60000", NULL};
	char **players[] = {pw, pa, al};
	for (size_t i = 0; i < sizeof players / sizeof players[0]; i++) {
		if (!program_on_path(players[i][0])) continue;
		int fds[2];
		if (pipe(fds) != 0) return -1;
		fcntl(fds[0], F_SETFD, FD_CLOEXEC);
		fcntl(fds[1], F_SETFD, FD_CLOEXEC);
		posix_spawn_file_actions_t fa;
		posix_spawn_file_actions_init(&fa);
		posix_spawn_file_actions_adddup2(&fa, fds[0], STDIN_FILENO);
		posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
		posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
		pid_t pid;
		int rc = posix_spawnp(&pid, players[i][0], &fa, NULL, players[i], environ);
		posix_spawn_file_actions_destroy(&fa);
		close(fds[0]);
		if (rc != 0) {
			close(fds[1]);
			continue;
		}
#ifdef F_SETPIPE_SZ
		/* Small pipe bounds audio latency; full pipe means we drop samples. */
		fcntl(fds[1], F_SETPIPE_SZ, 4096);
#endif
		fcntl(fds[1], F_SETFL, O_NONBLOCK);
		ps.audio_fd = fds[1];
		ps.audio_pid = pid;
		return 0;
	}
	return -1;
}

void plat_audio_write(const int16_t *samples, size_t count) {
	if (ps.audio_fd < 0) return;
	ssize_t n = write(ps.audio_fd, samples, count * sizeof *samples);
	if (n < 0 && errno == EPIPE) {
		close(ps.audio_fd);
		ps.audio_fd = -1;
	}
}

bool plat_audio_active(void) { return ps.audio_fd >= 0; }

void plat_audio_close(void) {
	if (ps.audio_fd >= 0) {
		close(ps.audio_fd);
		ps.audio_fd = -1;
	}
	if (ps.audio_coreaudio) {
		coreaudio_stop();
		ps.audio_coreaudio = false;
	}
	if (ps.audio_pid > 0) {
		/* Give the player a moment to drain, then insist. */
		for (int i = 0; i < 20; i++) {
			if (waitpid(ps.audio_pid, NULL, WNOHANG) == ps.audio_pid) {
				ps.audio_pid = -1;
				return;
			}
			struct timespec ts = {0, 10000000};
			nanosleep(&ts, NULL);
		}
		kill(ps.audio_pid, SIGTERM);
		waitpid(ps.audio_pid, NULL, 0);
		ps.audio_pid = -1;
	}
}

/* ---------- files ---------- */

char *plat_default_scores_path(void) {
	char buf[4096];
	const char *home = getenv("HOME");
#if defined(__APPLE__)
	if (!home || !*home) return NULL;
	snprintf(buf, sizeof buf, "%s/Library/Application Support/pinterm/scores.txt", home);
#else
	const char *xdg = getenv("XDG_DATA_HOME");
	if (xdg && *xdg == '/') snprintf(buf, sizeof buf, "%s/pinterm/scores.txt", xdg);
	else if (home && *home) snprintf(buf, sizeof buf, "%s/.local/share/pinterm/scores.txt", home);
	else return NULL;
#endif
	return strdup(buf);
}

int plat_make_parents(const char *path) {
	char dir[4096];
	if (snprintf(dir, sizeof dir, "%s", path) >= (int)sizeof dir) return -1;
	for (char *p = dir + 1; *p; p++) {
		if (*p != '/') continue;
		*p = '\0';
		if (mkdir(dir, 0700) != 0 && errno != EEXIST) return -1;
		*p = '/';
	}
	return 0;
}

int plat_sync_file(FILE *f) { return fsync(fileno(f)); }

int plat_replace_file(const char *src, const char *dst) { return rename(src, dst); }
#endif
