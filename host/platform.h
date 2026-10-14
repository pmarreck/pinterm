/* Operating-system adapter for the native frontend: terminal, frame clock,
 * interrupt/resize/suspend notifications, live audio and file primitives.
 * host/pinterm.c holds everything platform-neutral (CLI, headless replay,
 * the Roc adapter functions, score files) and reaches the OS only through
 * this interface; host/platform_posix.c and host/platform_win32.c implement it. */
#ifndef PINTERM_PLATFORM_H
#define PINTERM_PLATFORM_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* Process setup before anything is written (binary stdio, UTF-8 console). */
void plat_init(void);
/* "linux", "macos" or "windows". */
const char *plat_os_name(void);
/* Whether the terminal can be assumed to show 24-bit color when the
 * environment does not say (every VT-capable Windows console can). */
bool plat_console_truecolor(void);
long plat_pid(void);

/* ----- terminal ----- */
bool plat_stdout_is_terminal(void);
/* Find the terminal to read keys from. Returns 0, or -1 with no terminal. */
int plat_term_open_input(void);
/* Raw, unechoed, nonblocking input plus the enter sequence `enter`.
 * Returns 0, or -1 with errno set. */
int plat_term_enter(const char *enter, size_t enter_length);
/* Undo plat_term_enter, writing `leave` first. Safe to call repeatedly and
 * from a POSIX signal handler. */
void plat_term_restore(void);
/* Columns and rows; 80x24 when unknown. */
void plat_term_size(int *cols, int *rows);
/* Pending input bytes, without waiting. */
size_t plat_term_read(uint8_t *buf, size_t capacity);
void plat_term_write(const void *bytes, size_t length);

/* ----- notifications (interrupt, close, resize, suspend, crash) ----- */
/* `leave` is written by plat_term_restore, including on crashes. */
void plat_install_handlers(const char *leave, size_t leave_length);
bool plat_quit_requested(void);
/* True once after each resize (and once initially). */
bool plat_take_resized(void);
void plat_mark_resized(void);
/* Suspend request (Ctrl-Z on POSIX, or Host.control from the core). */
void plat_request_suspend(void);
bool plat_take_suspend(void);
/* Stop until resumed, restoring the terminal meanwhile; re-enters raw mode
 * with `enter`. A no-op where job control does not exist. */
void plat_suspend(const char *enter, size_t enter_length);

/* ----- clock ----- */
/* Monotonic microseconds. */
uint64_t plat_now_us(void);
/* Sleep until plat_now_us() reaches deadline_us (returns early on quit). */
void plat_sleep_until_us(uint64_t deadline_us);

/* ----- live audio: mono s16 PCM at `rate` Hz ----- */
/* Starts playback; returns 0, or -1 when no output is available. */
int plat_audio_open(int rate);
/* Queues samples, dropping them when the device is behind. */
void plat_audio_write(const int16_t *samples, size_t count);
bool plat_audio_active(void);
void plat_audio_close(void);

/* ----- files ----- */
/* Per-user score file path (malloc'd), or NULL when there is no home. */
char *plat_default_scores_path(void);
/* Create the missing parent directories of path. Returns 0 or -1. */
int plat_make_parents(const char *path);
/* Flush a written file to stable storage. Returns 0 or -1. */
int plat_sync_file(FILE *f);
/* Atomically replace dst with src (same directory). Returns 0 or -1. */
int plat_replace_file(const char *src, const char *dst);
#endif
