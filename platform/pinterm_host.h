/* Adapter interface between the Roc platform ABI shim (platform/host.c) and
 * the native terminal/audio frontend (host/). All buffers are pointer+length. */
#ifndef PINTERM_HOST_H
#define PINTERM_HOST_H
#include <stddef.h>
#include <stdint.h>

/* Config slots returned to Roc by Host.config!. */
enum {
	PT_CFG_COLS, PT_CFG_ROWS, PT_CFG_COLOR, PT_CFG_ASCII, PT_CFG_SOUND,
	PT_CFG_SEED, PT_CFG_SAMPLE_RATE, PT_CFG_HEADLESS, PT_CFG_MAX_FRAMES,
	PT_CFG_FPS, PT_CFG_COUNT
};
/* Tick packet header: u64 now_us, u16 cols, u16 rows, u8 flags, then input bytes. */
enum { PT_TICK_HEADER = 13, PT_TICK_MAX_INPUT = 4096 };
enum { PT_FLAG_QUIT = 1, PT_FLAG_RESIZED = 2 };

void pt_config(int64_t out[PT_CFG_COUNT]);
void pt_present(const uint8_t *bytes, size_t length);
void pt_audio(const int16_t *samples, size_t count);
/* Waits for the next frame deadline, then fills header + pending input. */
size_t pt_tick(uint8_t *packet, size_t capacity);
/* Newline-terminated structured event lines (headless evidence log). */
void pt_log(const uint8_t *bytes, size_t length);
/* Saved high scores: the whole file (empty if none or no file is in use),
 * and an atomic replacement of it. */
enum { PT_SCORES_MAX = 65536 };
size_t pt_load_scores(uint8_t *buf, size_t capacity);
void pt_save_scores(const uint8_t *bytes, size_t length);
/* Control requests from the core. QUARANTINE_SCORES sets an unreadable score
 * file aside instead of letting the next save overwrite it. */
enum { PT_CONTROL_SUSPEND = 1, PT_CONTROL_QUARANTINE_SCORES = 2 };
void pt_control(uint8_t code);
#endif
