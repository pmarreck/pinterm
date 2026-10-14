/* Windows console key records to decoder bytes (see win_keys.h). */
#include "win_keys.h"
#include <stdio.h>
#include <string.h>

/* VT final byte for an arrow or paging key, 0 for other keys. */
static char vt_final(uint16_t vk) {
	switch (vk) {
	case WK_LEFT: return 'D';
	case WK_RIGHT: return 'C';
	case WK_DOWN: return 'B';
	case WK_UP: return 'A';
	default: return 0;
	}
}

/* Kitty key code (unshifted) for the character keys the game holds. */
static uint32_t held_char_code(uint32_t cp) {
	if (cp == 'Z') cp = 'z';
	return (cp == 'z' || cp == '/' || cp == ' ') ? cp : 0;
}

/* Keys whose hold matters to the game: flippers and the plunger. */
static bool is_hold_key(uint16_t vk, uint32_t cp) {
	return vk == WK_LEFT || vk == WK_RIGHT || vk == WK_DOWN || held_char_code(cp) != 0;
}

static size_t utf8(uint32_t cp, uint8_t *out) {
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

/* The plain bytes a first press sends. */
static size_t press_bytes(uint16_t vk, uint32_t cp, uint8_t *out) {
	char final = vt_final(vk);
	if (final) return (size_t)snprintf((char *)out, WIN_KEYS_MAX_BYTES, "\x1b[%c", final);
	if (vk == WK_PRIOR) return (size_t)snprintf((char *)out, WIN_KEYS_MAX_BYTES, "\x1b[5~");
	if (vk == WK_NEXT) return (size_t)snprintf((char *)out, WIN_KEYS_MAX_BYTES, "\x1b[6~");
	return cp ? utf8(cp, out) : 0;
}

/* Kitty event for a held key: 2 = repeat, 3 = release. */
static size_t kitty_event(uint16_t vk, uint32_t cp, int event, uint8_t *out) {
	char final = vt_final(vk);
	if (final) return (size_t)snprintf((char *)out, WIN_KEYS_MAX_BYTES, "\x1b[1;1:%d%c", event, final);
	return (size_t)snprintf((char *)out, WIN_KEYS_MAX_BYTES, "\x1b[%u;1:%du", (unsigned)held_char_code(cp), event);
}

size_t win_key_event(WinKeys *keys, uint16_t vk, bool key_down, uint32_t codepoint, uint8_t *out) {
	uint8_t slot = (uint8_t)vk;
	if (key_down) {
		if (!keys->down[slot]) {
			keys->down[slot] = true;
			keys->codepoint[slot] = codepoint;
			return press_bytes(vk, codepoint, out);
		}
		/* Autorepeat: game keys report repeats; others repeat the press. */
		uint32_t cp = keys->codepoint[slot];
		return is_hold_key(vk, cp) ? kitty_event(vk, cp, 2, out) : press_bytes(vk, cp, out);
	}
	if (!keys->down[slot]) return 0;
	keys->down[slot] = false;
	uint32_t cp = keys->codepoint[slot];
	return is_hold_key(vk, cp) ? kitty_event(vk, cp, 3, out) : 0;
}

size_t win_keys_focus_lost(WinKeys *keys, uint8_t *out, size_t capacity) {
	size_t n = 0;
	for (int vk = 0; vk < 256; vk++) {
		if (!keys->down[vk]) continue;
		keys->down[vk] = false;
		if (!is_hold_key((uint16_t)vk, keys->codepoint[vk])) continue;
		uint8_t event[WIN_KEYS_MAX_BYTES];
		size_t len = kitty_event((uint16_t)vk, keys->codepoint[vk], 3, event);
		if (n + len > capacity) break;
		memcpy(out + n, event, len);
		n += len;
	}
	return n;
}
