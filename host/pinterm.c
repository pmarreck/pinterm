/* pinterm native frontend: CLI parsing, terminal raw mode with guaranteed
 * restoration, frame pacing, nonblocking input, and streamed PCM audio through
 * an external player process. All game decisions live in the Roc core; this
 * adapter only moves bytes and keeps time. */
#include "pinterm_host.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef PINTERM_VERSION
#define PINTERM_VERSION "0.1.0"
#endif

extern uint8_t pinterm_run(void);
extern char **environ;

enum { SAMPLE_RATE = 22050, DEFAULT_FPS = 60, MIN_FPS = 20, MAX_FPS = 120 };
enum { COLOR_TRUE = 0, COLOR_256 = 1, COLOR_16 = 2, COLOR_MONO = 3 };
enum { DEFAULT_HEADLESS_COLS = 80, DEFAULT_HEADLESS_ROWS = 40 };

/* Terminal enter/leave sequences. Kitty keyboard flags 1|2 request key-release
 * reporting; terminals without the protocol ignore the push/pop. */
static const char TERM_ENTER[] = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[>3u\x1b[2J";
static const char TERM_LEAVE[] = "\x1b[<u\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l";

typedef struct ScriptEvent {
	uint64_t frame;
	uint8_t bytes[16];
	size_t length;
} ScriptEvent;

static struct {
	bool headless;
	bool ascii;
	int color;
	int sound; /* -1 auto, 0 off, 1 on */
	uint64_t seed;
	bool seed_given;
	int fps;
	uint64_t max_frames;
	int cols, rows;
	const char *script_path;
	const char *frames_out;
	const char *log_out;
	const char *audio_out;
	bool full_frames;
} opt = {.color = -1, .sound = -1, .fps = DEFAULT_FPS};

static struct {
	bool raw;
	struct termios saved;
	int tty_in;
	int out_fd;
	FILE *frames;
	FILE *log;
	int audio_fd;
	pid_t audio_pid;
	uint64_t frame;
	uint64_t now_us;
	struct timespec deadline;
	ScriptEvent *script;
	size_t script_count, script_next;
	int last_cols, last_rows;
} st = {.tty_in = -1, .out_fd = STDOUT_FILENO, .audio_fd = -1, .audio_pid = -1};

static volatile sig_atomic_t quit_requested;
static volatile sig_atomic_t resized = 1;
static volatile sig_atomic_t stop_requested;

static void write_all(int fd, const void *data, size_t length) {
	const uint8_t *p = data;
	while (length) {
		ssize_t n = write(fd, p, length);
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
static void terminal_restore(void) {
	if (!st.raw) return;
	st.raw = false;
	(void)!write(st.out_fd, TERM_LEAVE, sizeof TERM_LEAVE - 1);
	tcsetattr(st.tty_in, TCSAFLUSH, &st.saved);
}

static int terminal_enter(void) {
	if (tcgetattr(st.tty_in, &st.saved) != 0) return -1;
	struct termios raw = st.saved;
	raw.c_iflag &= ~(tcflag_t)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
	raw.c_oflag &= ~(tcflag_t)OPOST;
	raw.c_cflag |= CS8;
	raw.c_lflag &= ~(tcflag_t)(ECHO | ICANON | IEXTEN | ISIG);
	raw.c_cc[VMIN] = 0;
	raw.c_cc[VTIME] = 0;
	if (tcsetattr(st.tty_in, TCSAFLUSH, &raw) != 0) return -1;
	st.raw = true;
	write_all(st.out_fd, TERM_ENTER, sizeof TERM_ENTER - 1);
	return 0;
}

static void audio_close(void) {
	if (st.audio_fd >= 0) {
		close(st.audio_fd);
		st.audio_fd = -1;
	}
	if (st.audio_pid > 0) {
		/* Give the player a moment to drain, then insist. */
		for (int i = 0; i < 20; i++) {
			if (waitpid(st.audio_pid, NULL, WNOHANG) == st.audio_pid) {
				st.audio_pid = -1;
				return;
			}
			struct timespec ts = {0, 10000000};
			nanosleep(&ts, NULL);
		}
		kill(st.audio_pid, SIGTERM);
		waitpid(st.audio_pid, NULL, 0);
		st.audio_pid = -1;
	}
}

static void cleanup(void) {
	terminal_restore();
	audio_close();
	if (st.frames) fflush(st.frames);
	if (st.log) fflush(st.log);
}

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
	terminal_restore();
	signal(sig, SIG_DFL);
	raise(sig);
}

static void install_signals(void) {
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

static void suspend_self(void) {
	terminal_restore();
	audio_close();
	/* SIGSTOP rather than SIGTSTP: POSIX discards default-stop TSTP in
	 * orphaned process groups, which would leave the game un-suspended. */
	raise(SIGSTOP);
	/* Resumed by SIGCONT. */
	if (terminal_enter() != 0) quit_requested = 1;
	resized = 1;
	clock_gettime(CLOCK_MONOTONIC, &st.deadline);
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

static void audio_open(void) {
	if (opt.audio_out) {
		int fd = strcmp(opt.audio_out, "-") == 0 ? dup(STDOUT_FILENO)
			: open(opt.audio_out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
		st.audio_fd = fd;
		return;
	}
	static char *pw[] = {"pw-play", "--rate=22050", "--channels=1", "--format=s16", "--latency=40ms", "-", NULL};
	static char *pa[] = {"paplay", "--raw", "--rate=22050", "--channels=1", "--format=s16le", "--latency-msec=40", NULL};
	static char *al[] = {"aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", "22050", "-c", "1", "--buffer-time=60000", NULL};
	char **players[] = {pw, pa, al};
	for (size_t i = 0; i < sizeof players / sizeof players[0]; i++) {
		if (!program_on_path(players[i][0])) continue;
		int fds[2];
		if (pipe2(fds, O_CLOEXEC) != 0) return;
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
		/* Small pipe bounds audio latency; full pipe means we drop samples. */
		fcntl(fds[1], F_SETPIPE_SZ, 4096);
		fcntl(fds[1], F_SETFL, O_NONBLOCK);
		st.audio_fd = fds[1];
		st.audio_pid = pid;
		return;
	}
}

/* ---------- adapter interface ---------- */

void pt_config(int64_t out[PT_CFG_COUNT]) {
	out[PT_CFG_COLS] = st.last_cols;
	out[PT_CFG_ROWS] = st.last_rows;
	out[PT_CFG_COLOR] = opt.color;
	out[PT_CFG_ASCII] = opt.ascii;
	out[PT_CFG_SOUND] = st.audio_fd >= 0;
	out[PT_CFG_SEED] = (int64_t)opt.seed;
	out[PT_CFG_SAMPLE_RATE] = SAMPLE_RATE;
	out[PT_CFG_HEADLESS] = opt.headless;
	out[PT_CFG_MAX_FRAMES] = (int64_t)opt.max_frames;
	out[PT_CFG_FPS] = opt.fps;
}

void pt_present(const uint8_t *bytes, size_t length) {
	if (opt.headless) {
		if (st.frames) {
			fprintf(st.frames, "\n=== frame %llu ===\n", (unsigned long long)st.frame);
			fwrite(bytes, 1, length, st.frames);
		}
		return;
	}
	write_all(st.out_fd, bytes, length);
}

void pt_audio(const int16_t *samples, size_t count) {
	if (st.audio_fd < 0 || !count) return;
	if (opt.audio_out) {
		write_all(st.audio_fd, samples, count * sizeof *samples);
		return;
	}
	ssize_t n = write(st.audio_fd, samples, count * sizeof *samples);
	if (n < 0 && errno == EPIPE) {
		close(st.audio_fd);
		st.audio_fd = -1;
	}
}

void pt_log(const uint8_t *bytes, size_t length) {
	if (st.log) fwrite(bytes, 1, length, st.log);
}

void pt_control(uint8_t code) {
	if (code == PT_CONTROL_SUSPEND && !opt.headless) stop_requested = 1;
}

static void query_size(void) {
	if (opt.headless) {
		st.last_cols = opt.cols;
		st.last_rows = opt.rows;
		return;
	}
	struct winsize ws;
	if (ioctl(st.out_fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col && ws.ws_row) {
		st.last_cols = ws.ws_col;
		st.last_rows = ws.ws_row;
	} else {
		st.last_cols = 80;
		st.last_rows = 24;
	}
}

static void put_u64(uint8_t *p, uint64_t v) {
	for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

size_t pt_tick(uint8_t *packet, size_t capacity) {
	uint8_t flags = 0;
	size_t n = PT_TICK_HEADER;
	uint64_t frame_us = 1000000u / (unsigned)opt.fps;
	st.frame++;
	if (opt.headless) {
		/* Exact frame clock: no accumulated rounding of 1e6/fps. */
		st.now_us = st.frame * 1000000u / (unsigned)opt.fps;
		while (st.script_next < st.script_count && st.script[st.script_next].frame <= st.frame) {
			ScriptEvent *e = &st.script[st.script_next++];
			if (n + e->length <= capacity) {
				memcpy(packet + n, e->bytes, e->length);
				n += e->length;
			}
		}
		if (opt.full_frames) resized = 1;
		if (opt.max_frames && st.frame >= opt.max_frames) flags |= PT_FLAG_QUIT;
	} else {
		if (stop_requested) {
			stop_requested = 0;
			suspend_self();
		}
		st.deadline.tv_nsec += (long)(frame_us * 1000u);
		while (st.deadline.tv_nsec >= 1000000000L) {
			st.deadline.tv_nsec -= 1000000000L;
			st.deadline.tv_sec++;
		}
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		int64_t late_ns = (int64_t)(now.tv_sec - st.deadline.tv_sec) * 1000000000LL + (now.tv_nsec - st.deadline.tv_nsec);
		if (late_ns > (int64_t)frame_us * 3000) st.deadline = now; /* fell behind: resync */
		else
			while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &st.deadline, NULL) == EINTR && !quit_requested) {}
		clock_gettime(CLOCK_MONOTONIC, &now);
		st.now_us = (uint64_t)now.tv_sec * 1000000u + (uint64_t)now.tv_nsec / 1000u;
		while (n < capacity) {
			ssize_t r = read(st.tty_in, packet + n, capacity - n);
			if (r <= 0) break;
			n += (size_t)r;
		}
		if (opt.max_frames && st.frame >= opt.max_frames) flags |= PT_FLAG_QUIT;
	}
	if (resized) {
		resized = 0;
		flags |= PT_FLAG_RESIZED;
		query_size();
	}
	if (quit_requested) flags |= PT_FLAG_QUIT;
	put_u64(packet, st.now_us);
	packet[8] = (uint8_t)(st.last_cols & 0xff);
	packet[9] = (uint8_t)(st.last_cols >> 8);
	packet[10] = (uint8_t)(st.last_rows & 0xff);
	packet[11] = (uint8_t)(st.last_rows >> 8);
	packet[12] = flags;
	return n;
}

/* ---------- CLI ---------- */

static const struct {
	const char *name;
	const char *bytes;
} KEY_NAMES[] = {
	{"space", " "}, {"enter", "\r"}, {"left", "\x1b[D"}, {"right", "\x1b[C"},
	{"up", "\x1b[A"}, {"down", "\x1b[B"}, {"esc", "\x1b"}, {"ctrl-c", "\x03"},
	/* Kitty protocol releases (CSI keycode;1:3u) for scripted enhanced input. */
	{"release-z", "\x1b[122;1:3u"}, {"release-slash", "\x1b[47;1:3u"},
	{"release-space", "\x1b[32;1:3u"},
};

static int parse_key(const char *word, ScriptEvent *e) {
	for (size_t i = 0; i < sizeof KEY_NAMES / sizeof KEY_NAMES[0]; i++) {
		if (strcmp(word, KEY_NAMES[i].name) == 0) {
			e->length = strlen(KEY_NAMES[i].bytes);
			memcpy(e->bytes, KEY_NAMES[i].bytes, e->length);
			return 0;
		}
	}
	if (strlen(word) == 1) {
		e->bytes[0] = (uint8_t)word[0];
		e->length = 1;
		return 0;
	}
	return -1;
}

/* Script lines: "<frame> <key>", '#' comments. Keys: single chars or names. */
static int load_script(const char *path) {
	FILE *f = (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) ? stdin : fopen(path, "r");
	if (!f) {
		fprintf(stderr, "pinterm: cannot open script %s: %s\n", path, strerror(errno));
		return -1;
	}
	char line[256];
	size_t cap = 0;
	unsigned lineno = 0;
	while (fgets(line, sizeof line, f)) {
		lineno++;
		char *hash = strchr(line, '#');
		if (hash) *hash = 0;
		unsigned long long frame;
		char word[64];
		int got = sscanf(line, "%llu %63s", &frame, word);
		if (got <= 0) continue;
		if (got != 2) {
			fprintf(stderr, "pinterm: script line %u: expected '<frame> <key>'\n", lineno);
			return -1;
		}
		if (st.script_count == cap) {
			cap = cap ? cap * 2 : 64;
			st.script = realloc(st.script, cap * sizeof *st.script);
			if (!st.script) abort();
		}
		ScriptEvent *e = &st.script[st.script_count];
		e->frame = frame;
		if (parse_key(word, e) != 0) {
			fprintf(stderr, "pinterm: script line %u: unknown key '%s'\n", lineno, word);
			return -1;
		}
		if (st.script_count && frame < st.script[st.script_count - 1].frame) {
			fprintf(stderr, "pinterm: script line %u: frames must not decrease\n", lineno);
			return -1;
		}
		st.script_count++;
	}
	if (f != stdin) fclose(f);
	return 0;
}

static void usage(FILE *out) {
	fputs(
		"pinterm - top-down terminal pinball\n"
		"\n"
		"Usage: pinterm [options]\n"
		"\n"
		"Controls:\n"
		"  z / Left arrow / Left Shift*   left flipper\n"
		"  / / Right arrow / Right Shift* right flipper\n"
		"  Space / Down arrow             pull plunger (hold, release to launch)\n"
		"  t / Up arrow                   nudge the table (careful: tilt)\n"
		"  [ / ] or PageUp / PageDown     change table (between games)\n"
		"  p          pause      m  mute      h / ?  help\n"
		"  n          new game   q / Esc  quit\n"
		"  (* Shift keys only on terminals with the kitty keyboard protocol)\n"
		"\n"
		"Options:\n"
		"  -h, --help             show this help\n"
		"      --about            one-line description, version and platform\n"
		"      --ascii, --simple  plain ASCII glyphs and no color\n"
		"      --no-color, --no-ansi  monochrome (implies no color escapes beyond layout)\n"
		"      --colors MODE      truecolor | 256 | 16 | mono (default: auto)\n"
		"      --mute             disable sound      --sound  force sound on (e.g. over SSH)\n"
		"      --seed N           deterministic table randomness\n"
		"      --fps N            frame rate, 20-120 (default 60)\n"
		"\n"
		"Headless replay (testing):\n"
		"      --headless         no terminal; fixed clock; frames go to --frames-out\n"
		"      --size COLSxROWS   headless terminal size (default 80x40)\n"
		"      --frames N         stop after N frames\n"
		"      --script FILE      scripted input: lines '<frame> <key>' (- or @stdin)\n"
		"      --frames-out FILE  write rendered frames (- or @stdout, @stderr)\n"
		"      --log-out FILE     write structured game events (- or @stdout, @stderr)\n"
		"      --audio-out FILE   write raw s16le 22050 Hz mono PCM instead of playing\n"
		"      --full-frames      redraw every frame completely (viewable dumps)\n"		"\n"
		"Environment: PINTERM_MUTE=1 disables sound. Sound is off by default over SSH.\n",
		out);
}

static FILE *open_out(const char *path) {
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0) return stdout;
	if (strcmp(path, "@stderr") == 0) return stderr;
	FILE *f = fopen(path, "w");
	if (!f) fprintf(stderr, "pinterm: cannot write %s: %s\n", path, strerror(errno));
	return f;
}

static const char *arch_name(void) {
#if defined(__x86_64__)
	return "x86_64";
#elif defined(__aarch64__)
	return "aarch64";
#else
	return "unknown-arch";
#endif
}

static int parse_int(const char *s, long long lo, long long hi, long long *out) {
	char *end;
	errno = 0;
	long long v = strtoll(s, &end, 10);
	if (errno || *end || end == s || v < lo || v > hi) return -1;
	*out = v;
	return 0;
}

/* Accepts "--opt value" and "--opt=value". Returns value or NULL. */
static const char *opt_value(int argc, char **argv, int *i, const char *name) {
	size_t len = strlen(name);
	if (strncmp(argv[*i], name, len) != 0) return NULL;
	if (argv[*i][len] == '=') return argv[*i] + len + 1;
	if (argv[*i][len] == 0) {
		if (*i + 1 >= argc) {
			fprintf(stderr, "pinterm: %s needs a value\n", name);
			exit(2);
		}
		return argv[++*i];
	}
	return NULL;
}

static void parse_args(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v;
		long long n;
		if (!strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "/?") || !strcmp(a, "/h")) {
			usage(stdout);
			exit(0);
		} else if (!strcmp(a, "--about")) {
			printf("pinterm %s - top-down terminal pinball with a Roc core (linux %s)\n", PINTERM_VERSION, arch_name());
			exit(0);
		} else if (!strcmp(a, "--version")) {
			printf("pinterm %s\n", PINTERM_VERSION);
			exit(0);
		} else if (!strcmp(a, "--ascii") || !strcmp(a, "--simple")) {
			opt.ascii = true;
			opt.color = COLOR_MONO;
		} else if (!strcmp(a, "--no-color") || !strcmp(a, "--no-ansi")) {
			opt.color = COLOR_MONO;
		} else if ((v = opt_value(argc, argv, &i, "--colors"))) {
			if (!strcmp(v, "truecolor") || !strcmp(v, "24bit")) opt.color = COLOR_TRUE;
			else if (!strcmp(v, "256")) opt.color = COLOR_256;
			else if (!strcmp(v, "16")) opt.color = COLOR_16;
			else if (!strcmp(v, "mono") || !strcmp(v, "none")) opt.color = COLOR_MONO;
			else {
				fprintf(stderr, "pinterm: unknown color mode '%s'\n", v);
				exit(2);
			}
		} else if (!strcmp(a, "--mute")) {
			opt.sound = 0;
		} else if (!strcmp(a, "--sound")) {
			opt.sound = 1;
		} else if ((v = opt_value(argc, argv, &i, "--seed"))) {
			if (parse_int(v, 0, INT64_MAX, &n)) {
				fprintf(stderr, "pinterm: invalid seed '%s'\n", v);
				exit(2);
			}
			opt.seed = (uint64_t)n;
			opt.seed_given = true;
		} else if ((v = opt_value(argc, argv, &i, "--fps"))) {
			if (parse_int(v, MIN_FPS, MAX_FPS, &n)) {
				fprintf(stderr, "pinterm: --fps must be %d-%d\n", MIN_FPS, MAX_FPS);
				exit(2);
			}
			opt.fps = (int)n;
		} else if (!strcmp(a, "--headless")) {
			opt.headless = true;
		} else if (!strcmp(a, "--full-frames")) {
			opt.full_frames = true;
		} else if ((v = opt_value(argc, argv, &i, "--size"))) {
			int c, r;
			char x;
			if (sscanf(v, "%d%c%d", &c, &x, &r) != 3 || (x != 'x' && x != 'X') || c < 20 || r < 10 || c > 1000 || r > 500) {
				fprintf(stderr, "pinterm: invalid --size '%s' (want COLSxROWS)\n", v);
				exit(2);
			}
			opt.cols = c;
			opt.rows = r;
		} else if ((v = opt_value(argc, argv, &i, "--frames"))) {
			if (parse_int(v, 1, 100000000, &n)) {
				fprintf(stderr, "pinterm: invalid --frames '%s'\n", v);
				exit(2);
			}
			opt.max_frames = (uint64_t)n;
		} else if ((v = opt_value(argc, argv, &i, "--script"))) {
			opt.script_path = v;
		} else if ((v = opt_value(argc, argv, &i, "--frames-out"))) {
			opt.frames_out = v;
		} else if ((v = opt_value(argc, argv, &i, "--log-out"))) {
			opt.log_out = v;
		} else if ((v = opt_value(argc, argv, &i, "--audio-out"))) {
			opt.audio_out = v;
		} else {
			fprintf(stderr, "pinterm: unknown option '%s' (try --help)\n", a);
			exit(2);
		}
	}
}

static int color_from_env(void) {
	const char *nc = getenv("NO_COLOR");
	if (nc && *nc) return COLOR_MONO;
	const char *ct = getenv("COLORTERM");
	if (ct && (strstr(ct, "truecolor") || strstr(ct, "24bit"))) return COLOR_TRUE;
	const char *term = getenv("TERM");
	if (term && (strstr(term, "kitty") || strstr(term, "ghostty") || strstr(term, "wezterm") ||
		strstr(term, "foot") || strstr(term, "alacritty") || strstr(term, "direct"))) return COLOR_TRUE;
	if (term && strstr(term, "256color")) return COLOR_256;
	if (term && !strcmp(term, "dumb")) return COLOR_MONO;
	return COLOR_16;
}

int main(int argc, char **argv) {
#ifdef PINTERM_DEBUG_BUILD
	if (!getenv("MUTE_DEBUG_STATUS")) fputs("\x1b[33mDEBUG BUILD!\x1b[0m\n", stderr);
#endif
	parse_args(argc, argv);
	if (!opt.seed_given) opt.seed = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 20);
	if (opt.color < 0) opt.color = opt.headless ? COLOR_TRUE : color_from_env();
	if (opt.headless) {
		if (!opt.cols) {
			opt.cols = DEFAULT_HEADLESS_COLS;
			opt.rows = DEFAULT_HEADLESS_ROWS;
		}
		if (!opt.max_frames) opt.max_frames = 600000; /* bounded even if the script forgets */
		if (opt.script_path && load_script(opt.script_path) != 0) return 2;
		if (opt.frames_out && !(st.frames = open_out(opt.frames_out))) return 1;
		if (opt.log_out && !(st.log = open_out(opt.log_out))) return 1;
		if (opt.audio_out && opt.sound != 0) audio_open();
	} else {
		if (opt.script_path || opt.frames_out || opt.log_out) {
			fputs("pinterm: --script/--frames-out/--log-out require --headless\n", stderr);
			return 2;
		}
		if (!isatty(STDOUT_FILENO)) {
			fputs("pinterm: stdout is not a terminal (use --headless for scripted runs)\n", stderr);
			return 1;
		}
		st.tty_in = isatty(STDIN_FILENO) ? STDIN_FILENO : open("/dev/tty", O_RDONLY | O_CLOEXEC);
		if (st.tty_in < 0) {
			fputs("pinterm: no terminal for input\n", stderr);
			return 1;
		}
		const char *mute = getenv("PINTERM_MUTE");
		bool remote = getenv("SSH_CONNECTION") || getenv("SSH_TTY") || getenv("SSH_CLIENT");
		if (mute && *mute && strcmp(mute, "0") != 0 && opt.sound < 0) opt.sound = 0;
		if (opt.sound < 0) opt.sound = remote ? 0 : 1;
		if (opt.sound) audio_open();
	}
	install_signals();
	atexit(cleanup);
	if (!opt.headless) {
		if (terminal_enter() != 0) {
			fprintf(stderr, "pinterm: cannot configure terminal: %s\n", strerror(errno));
			return 1;
		}
		clock_gettime(CLOCK_MONOTONIC, &st.deadline);
	}
	query_size();
	resized = 1;
	uint8_t status = pinterm_run();
	cleanup();
	return status;
}
