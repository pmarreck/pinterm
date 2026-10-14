/* pinterm native frontend: CLI parsing, headless replay, frame pacing and the
 * adapter functions the Roc core calls (present, audio, tick, scores). All
 * game decisions live in the Roc core; this file only moves bytes and keeps
 * time, and reaches the operating system through host/platform.h. */
#include "pinterm_host.h"
#include "platform.h"
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef PINTERM_VERSION
#define PINTERM_VERSION "0.1.0"
#endif

extern uint8_t pinterm_run(void);

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
	const char *scores_path;
	bool full_frames;
} opt = {.color = -1, .sound = -1, .fps = DEFAULT_FPS};

static struct {
	FILE *frames;
	FILE *log;
	FILE *audio_file; /* --audio-out capture instead of live playback */
	uint64_t frame;
	uint64_t now_us;
	uint64_t deadline_us;
	ScriptEvent *script;
	size_t script_count, script_next;
	int last_cols, last_rows;
	char *scores_path; /* NULL: no score file in use */
	char warning[1024]; /* shown on stderr once the terminal is restored */
} st;

static void cleanup(void) {
	plat_term_restore();
	plat_audio_close();
	if (st.audio_file) fflush(st.audio_file);
	if (st.frames) fflush(st.frames);
	if (st.log) fflush(st.log);
	if (st.warning[0]) {
		fputs(st.warning, stderr);
		st.warning[0] = '\0';
	}
}

static void audio_open(void) {
	if (opt.audio_out) {
		st.audio_file = strcmp(opt.audio_out, "-") == 0 ? stdout : fopen(opt.audio_out, "wb");
		return;
	}
	plat_audio_open(SAMPLE_RATE);
}

static bool sound_on(void) { return st.audio_file || plat_audio_active(); }

/* ---------- adapter interface ---------- */

void pt_config(int64_t out[PT_CFG_COUNT]) {
	out[PT_CFG_COLS] = st.last_cols;
	out[PT_CFG_ROWS] = st.last_rows;
	out[PT_CFG_COLOR] = opt.color;
	out[PT_CFG_ASCII] = opt.ascii;
	out[PT_CFG_SOUND] = sound_on();
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
	plat_term_write(bytes, length);
}

void pt_audio(const int16_t *samples, size_t count) {
	if (!count) return;
	if (st.audio_file) {
		fwrite(samples, sizeof *samples, count, st.audio_file);
		return;
	}
	plat_audio_write(samples, count);
}

void pt_log(const uint8_t *bytes, size_t length) {
	if (st.log) fwrite(bytes, 1, length, st.log);
}

/* Remember a score-file problem for stderr; printed after the terminal is restored. */
static void scores_warn(const char *what, const char *path) {
	size_t n = strlen(st.warning);
	snprintf(st.warning + n, sizeof st.warning - n, "pinterm: %s %s: %s\n", what, path, errno ? strerror(errno) : "unknown error");
}

/* ---------- high-score file ---------- */

/* Where saved scores live: --scores PATH, else $PINTERM_SCORES, else (never
 * for headless runs, so tests and replays cannot touch real scores) the
 * platform's per-user data directory. Returns NULL for "no file". */
static char *scores_path_resolve(void) {
	if (opt.scores_path) return strdup(opt.scores_path);
	const char *env = getenv("PINTERM_SCORES");
	if (env && *env) return strdup(env);
	if (opt.headless) return NULL;
	return plat_default_scores_path();
}

/* Whole file, at most PT_SCORES_MAX bytes; empty when missing or unreadable. */
size_t pt_load_scores(uint8_t *buf, size_t capacity) {
	if (!st.scores_path) return 0;
	FILE *f = fopen(st.scores_path, "rb");
	if (!f) {
		if (errno != ENOENT) scores_warn("cannot read", st.scores_path);
		return 0;
	}
	size_t n = fread(buf, 1, capacity, f);
	fclose(f);
	return n;
}

/* Atomic replace: write a sibling temp file, flush it to disk, rename. */
void pt_save_scores(const uint8_t *bytes, size_t length) {
	if (!st.scores_path) return;
	char tmp[4200];
	snprintf(tmp, sizeof tmp, "%s.tmp-%ld", st.scores_path, plat_pid());
	FILE *f = NULL;
	if (plat_make_parents(st.scores_path) != 0 || !(f = fopen(tmp, "wb")) ||
		fwrite(bytes, 1, length, f) != length || fflush(f) != 0 || plat_sync_file(f) != 0) {
		if (f) fclose(f);
		remove(tmp);
		scores_warn("cannot save", st.scores_path);
		return;
	}
	fclose(f);
	if (plat_replace_file(tmp, st.scores_path) != 0) {
		remove(tmp);
		scores_warn("cannot save", st.scores_path);
	}
}

/* Keep an unreadable file for inspection instead of overwriting it. */
static void pt_quarantine_scores(void) {
	if (!st.scores_path) return;
	char bad[4200];
	snprintf(bad, sizeof bad, "%s.bad-%lld", st.scores_path, (long long)time(NULL));
	if (rename(st.scores_path, bad) != 0) {
		scores_warn("cannot set aside a damaged score file", st.scores_path);
		return;
	}
	size_t n = strlen(st.warning);
	snprintf(st.warning + n, sizeof st.warning - n, "pinterm: ignored a damaged score file; kept it as %s\n", bad);
}

void pt_control(uint8_t code) {
	if (code == PT_CONTROL_SUSPEND && !opt.headless) plat_request_suspend();
	if (code == PT_CONTROL_QUARANTINE_SCORES) pt_quarantine_scores();
}

static void query_size(void) {
	if (opt.headless) {
		st.last_cols = opt.cols;
		st.last_rows = opt.rows;
		return;
	}
	plat_term_size(&st.last_cols, &st.last_rows);
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
		if (opt.full_frames) plat_mark_resized();
		if (opt.max_frames && st.frame >= opt.max_frames) flags |= PT_FLAG_QUIT;
	} else {
		if (plat_take_suspend()) {
			plat_suspend(TERM_ENTER, sizeof TERM_ENTER - 1);
			st.deadline_us = plat_now_us();
		}
		st.deadline_us += frame_us;
		uint64_t now = plat_now_us();
		if (now > st.deadline_us && now - st.deadline_us > frame_us * 3) st.deadline_us = now; /* fell behind: resync */
		else
			plat_sleep_until_us(st.deadline_us);
		st.now_us = plat_now_us();
		n += plat_term_read(packet + n, capacity - n);
		if (opt.max_frames && st.frame >= opt.max_frames) flags |= PT_FLAG_QUIT;
	}
	if (plat_take_resized()) {
		flags |= PT_FLAG_RESIZED;
		query_size();
	}
	if (plat_quit_requested()) flags |= PT_FLAG_QUIT;
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
		"      --scores PATH      high-score file (default: $PINTERM_SCORES, else\n"
		"                         $XDG_DATA_HOME/pinterm/scores.txt; none when headless)\n"		"\n"
		"Headless replay (testing):\n"
		"      --headless         no terminal; fixed clock; frames go to --frames-out\n"
		"      --size COLSxROWS   headless terminal size (default 80x40)\n"
		"      --frames N         stop after N frames\n"
		"      --script FILE      scripted input: lines '<frame> <key>' (- or @stdin)\n"
		"      --frames-out FILE  write rendered frames (- or @stdout, @stderr)\n"
		"      --log-out FILE     write structured game events (- or @stdout, @stderr)\n"
		"      --audio-out FILE   write raw s16le 22050 Hz mono PCM instead of playing\n"
		"      --full-frames      redraw every frame completely (viewable dumps)\n"		"\n"
		"Environment: PINTERM_MUTE=1 disables sound. Sound is off by default over SSH.\n"
		"             PINTERM_SCORES=PATH sets the high-score file (--scores wins).\n",
		out);
}

static FILE *open_out(const char *path) {
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0) return stdout;
	if (strcmp(path, "@stderr") == 0) return stderr;
	FILE *f = fopen(path, "wb"); /* byte for byte, also on Windows */
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
			printf("pinterm %s - top-down terminal pinball with a Roc core (%s %s)\n", PINTERM_VERSION, plat_os_name(), arch_name());
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
		} else if ((v = opt_value(argc, argv, &i, "--scores"))) {
			if (!*v || !strcmp(v, "-") || !strcmp(v, "@stdin") || !strcmp(v, "@stdout") || !strcmp(v, "@stderr")) {
				fputs("pinterm: --scores needs a file path (it is read and rewritten)\n", stderr);
				exit(2);
			}
			opt.scores_path = v;
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
	if (!term && plat_console_truecolor()) return COLOR_TRUE;
	return COLOR_16;
}

int main(int argc, char **argv) {
	plat_init();
#ifdef PINTERM_DEBUG_BUILD
	if (!getenv("MUTE_DEBUG_STATUS")) fputs("\x1b[33mDEBUG BUILD!\x1b[0m\n", stderr);
#endif
	parse_args(argc, argv);
	if (!opt.seed_given) opt.seed = (uint64_t)time(NULL) ^ ((uint64_t)plat_pid() << 20);
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
		if (!plat_stdout_is_terminal()) {
			fputs("pinterm: stdout is not a terminal (use --headless for scripted runs)\n", stderr);
			return 1;
		}
		if (plat_term_open_input() != 0) {
			fputs("pinterm: no terminal for input\n", stderr);
			return 1;
		}
		const char *mute = getenv("PINTERM_MUTE");
		bool remote = getenv("SSH_CONNECTION") || getenv("SSH_TTY") || getenv("SSH_CLIENT");
		if (mute && *mute && strcmp(mute, "0") != 0 && opt.sound < 0) opt.sound = 0;
		if (opt.sound < 0) opt.sound = remote ? 0 : 1;
		if (opt.sound) audio_open();
	}
	plat_install_handlers(TERM_LEAVE, sizeof TERM_LEAVE - 1);
	atexit(cleanup);
	if (!opt.headless) {
		if (plat_term_enter(TERM_ENTER, sizeof TERM_ENTER - 1) != 0) {
			fprintf(stderr, "pinterm: cannot configure terminal: %s\n", strerror(errno));
			return 1;
		}
		st.deadline_us = plat_now_us();
	}
	st.scores_path = scores_path_resolve();
	query_size();
	plat_mark_resized();
	uint8_t status = pinterm_run();
	cleanup();
	return status;
}
