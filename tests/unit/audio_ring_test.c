/* audio_ring: FIFO order across wraparound, silence padding, and dropping the
 * oldest samples beyond the backlog cap. Built and run by
 * tests/integration/audio_ring_test. */
#include "audio_ring.h"
#include <stdio.h>

static int failures;
static void check(const char *name, int ok) {
	if (!ok) {
		failures++;
		printf("FAIL %s\n", name);
	}
}

static int16_t seq[64];

/* out[i] == first + i for i < n */
static int counts_from(const int16_t *out, size_t n, int first) {
	for (size_t i = 0; i < n; i++)
		if (out[i] != first + (int)i) return 0;
	return 1;
}

static int silent(const int16_t *out, size_t n) {
	for (size_t i = 0; i < n; i++)
		if (out[i]) return 0;
	return 1;
}

int main(void) {
	for (int i = 0; i < 64; i++) seq[i] = (int16_t)(i + 1);
	int16_t storage[8], out[16];
	AudioRing r;

	audio_ring_init(&r, storage, 8);
	check("empty pull returns 0", audio_ring_pull(&r, out, 4) == 0);
	check("empty pull is silence", silent(out, 4));

	audio_ring_init(&r, storage, 8);
	audio_ring_push(&r, seq, 3, 8);
	check("short pull returns what was queued", audio_ring_pull(&r, out, 5) == 3);
	check("short pull keeps order", counts_from(out, 3, 1));
	check("short pull pads with silence", silent(out + 3, 2));
	check("short pull empties the ring", r.length == 0);

	audio_ring_init(&r, storage, 8);
	audio_ring_push(&r, seq, 6, 8);
	audio_ring_pull(&r, out, 4);
	audio_ring_push(&r, seq + 6, 5, 8); /* wraps around the storage end */
	check("wrapped ring holds 7", r.length == 7);
	check("wrapped pull returns 7", audio_ring_pull(&r, out, 7) == 7);
	check("wrapped pull keeps order", counts_from(out, 7, 5));

	audio_ring_init(&r, storage, 8);
	audio_ring_push(&r, seq, 6, 4);
	check("backlog trimmed to keep", r.length == 4);
	audio_ring_pull(&r, out, 4);
	check("trim drops the oldest", counts_from(out, 4, 3));

	audio_ring_init(&r, storage, 8);
	audio_ring_push(&r, seq, 20, 100); /* keep clamps to capacity */
	check("overflow keeps capacity", r.length == 8);
	audio_ring_pull(&r, out, 8);
	check("overflow keeps the newest", counts_from(out, 8, 13));

	audio_ring_init(&r, storage, 8);
	audio_ring_push(&r, seq, 0, 8);
	check("empty push is a no-op", r.length == 0);

	printf("%d failures\n", failures);
	return failures != 0;
}
