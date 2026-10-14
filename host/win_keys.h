/* Translate Windows console key records into the byte stream the game's
 * input decoder reads, kitty keyboard protocol style: a key's first press is
 * its plain character or VT sequence, autorepeat of a game key is a repeat
 * event, and releasing a game key is a release event. Reporting releases for
 * every key the game holds (flippers and plunger) lets the core time holds
 * exactly. Pure and platform-independent so it is unit-tested everywhere;
 * host/platform_win32.c feeds it KEY_EVENT and FOCUS_EVENT records. */
#ifndef PINTERM_WIN_KEYS_H
#define PINTERM_WIN_KEYS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Windows virtual-key codes used here (same values as winuser.h). */
enum { WK_PRIOR = 0x21, WK_NEXT = 0x22, WK_LEFT = 0x25, WK_UP = 0x26, WK_RIGHT = 0x27, WK_DOWN = 0x28 };
enum { WIN_KEYS_MAX_BYTES = 32 };

typedef struct WinKeys {
	bool down[256];
	uint32_t codepoint[256]; /* character the key produced when pressed */
} WinKeys;

/* One key record: virtual key, pressed or released, and the Unicode
 * character it produced (0 for none). Writes at most WIN_KEYS_MAX_BYTES. */
size_t win_key_event(WinKeys *keys, uint16_t vk, bool key_down, uint32_t codepoint, uint8_t *out);
/* The window lost focus, so no key-up will arrive: release every held game
 * key, in virtual-key order. Writes at most `capacity` bytes. */
size_t win_keys_focus_lost(WinKeys *keys, uint8_t *out, size_t capacity);
#endif
