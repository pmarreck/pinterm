/* win_keys: Windows console key records to decoder bytes (plain first press,
 * kitty repeat and release events for the keys the game holds). Built and run
 * by tests/integration/win_keys_test. */
#include "win_keys.h"
#include <stdio.h>
#include <string.h>

static int failures;
static void check_bytes(const char *name, const uint8_t *got, size_t n, const char *want) {
	if (n != strlen(want) || memcmp(got, want, n) != 0) {
		failures++;
		printf("FAIL %s: got %zu bytes \"", name, n);
		for (size_t i = 0; i < n; i++) printf(got[i] == 0x1b ? "\\e" : "%c", got[i]);
		printf("\"\n");
	}
}

int main(void) {
	uint8_t out[64];
	size_t n;
	WinKeys k;

	/* Game keys: plain first press, kitty repeat while held, kitty release. */
	memset(&k, 0, sizeof k);
	n = win_key_event(&k, 'Z', true, 'z', out);
	check_bytes("z first press is plain", out, n, "z");
	n = win_key_event(&k, 'Z', true, 'z', out);
	check_bytes("z autorepeat is a kitty repeat", out, n, "\x1b[122;1:2u");
	n = win_key_event(&k, 'Z', false, 'z', out);
	check_bytes("z release is a kitty release", out, n, "\x1b[122;1:3u");
	n = win_key_event(&k, 'Z', false, 'z', out);
	check_bytes("release without press says nothing", out, n, "");

	memset(&k, 0, sizeof k);
	n = win_key_event(&k, 'Z', true, 'Z', out);
	check_bytes("shifted Z first press is plain", out, n, "Z");
	n = win_key_event(&k, 'Z', false, 0, out);
	check_bytes("Z release uses the lowercase key code", out, n, "\x1b[122;1:3u");

	memset(&k, 0, sizeof k);
	n = win_key_event(&k, 0xBF, true, '/', out);
	check_bytes("slash press", out, n, "/");
	n = win_key_event(&k, 0xBF, false, '/', out);
	check_bytes("slash release", out, n, "\x1b[47;1:3u");

	memset(&k, 0, sizeof k);
	n = win_key_event(&k, 0x20, true, ' ', out);
	check_bytes("space press", out, n, " ");
	n = win_key_event(&k, 0x20, false, ' ', out);
	check_bytes("space release", out, n, "\x1b[32;1:3u");

	/* Arrows: VT sequences, kitty repeat and release forms. */
	memset(&k, 0, sizeof k);
	n = win_key_event(&k, WK_LEFT, true, 0, out);
	check_bytes("left press", out, n, "\x1b[D");
	n = win_key_event(&k, WK_LEFT, true, 0, out);
	check_bytes("left repeat", out, n, "\x1b[1;1:2D");
	n = win_key_event(&k, WK_LEFT, false, 0, out);
	check_bytes("left release", out, n, "\x1b[1;1:3D");
	n = win_key_event(&k, WK_RIGHT, true, 0, out);
	check_bytes("right press", out, n, "\x1b[C");
	n = win_key_event(&k, WK_RIGHT, false, 0, out);
	check_bytes("right release", out, n, "\x1b[1;1:3C");
	n = win_key_event(&k, WK_DOWN, true, 0, out);
	check_bytes("down press", out, n, "\x1b[B");
	n = win_key_event(&k, WK_DOWN, false, 0, out);
	check_bytes("down release", out, n, "\x1b[1;1:3B");

	/* Press-only keys: no release; autorepeat repeats the press. */
	memset(&k, 0, sizeof k);
	n = win_key_event(&k, WK_UP, true, 0, out);
	check_bytes("up press (nudge)", out, n, "\x1b[A");
	n = win_key_event(&k, WK_UP, true, 0, out);
	check_bytes("up autorepeat repeats the press", out, n, "\x1b[A");
	n = win_key_event(&k, WK_UP, false, 0, out);
	check_bytes("up release says nothing", out, n, "");
	n = win_key_event(&k, WK_PRIOR, true, 0, out);
	check_bytes("page up", out, n, "\x1b[5~");
	n = win_key_event(&k, WK_NEXT, true, 0, out);
	check_bytes("page down", out, n, "\x1b[6~");
	n = win_key_event(&k, 'P', true, 'p', out);
	check_bytes("p press", out, n, "p");
	n = win_key_event(&k, 'P', true, 'p', out);
	check_bytes("p autorepeat repeats", out, n, "p");
	n = win_key_event(&k, 'P', false, 'p', out);
	check_bytes("p release says nothing", out, n, "");
	n = win_key_event(&k, 0x11, true, 0, out);
	check_bytes("ctrl alone says nothing", out, n, "");
	n = win_key_event(&k, 'C', true, 3, out);
	check_bytes("ctrl-c is byte 3", out, n, "\x03");
	n = win_key_event(&k, 0xDE, true, 0xE9, out);
	check_bytes("non-ASCII character as UTF-8", out, n, "\xc3\xa9");

	/* Losing focus releases every held game key, and only those. */
	memset(&k, 0, sizeof k);
	win_key_event(&k, 'Z', true, 'z', out);
	win_key_event(&k, WK_RIGHT, true, 0, out);
	win_key_event(&k, 'P', true, 'p', out);
	n = win_keys_focus_lost(&k, out, sizeof out);
	check_bytes("focus loss releases held game keys, in virtual-key order", out, n, "\x1b[1;1:3C\x1b[122;1:3u");
	n = win_key_event(&k, 'Z', false, 'z', out);
	check_bytes("late key-up after focus loss says nothing", out, n, "");
	n = win_keys_focus_lost(&k, out, 5);
	check_bytes("focus loss with nothing held", out, n, "");

	printf("%d failures\n", failures);
	return failures != 0;
}
