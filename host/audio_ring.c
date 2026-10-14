/* Bounded s16 FIFO with oldest-first dropping (see audio_ring.h). */
#include "audio_ring.h"
#include <string.h>

void audio_ring_init(AudioRing *ring, int16_t *storage, size_t capacity) {
	ring->samples = storage;
	ring->capacity = capacity;
	ring->head = 0;
	ring->length = 0;
}

static void drop_oldest(AudioRing *ring, size_t count) {
	ring->head = (ring->head + count) % ring->capacity;
	ring->length -= count;
}

void audio_ring_push(AudioRing *ring, const int16_t *samples, size_t count, size_t keep) {
	if (!ring->capacity) return;
	if (keep > ring->capacity) keep = ring->capacity;
	/* Only the newest `capacity` samples can survive. */
	if (count > ring->capacity) {
		samples += count - ring->capacity;
		count = ring->capacity;
	}
	if (ring->length + count > ring->capacity) drop_oldest(ring, ring->length + count - ring->capacity);
	for (size_t i = 0; i < count; i++) ring->samples[(ring->head + ring->length + i) % ring->capacity] = samples[i];
	ring->length += count;
	if (ring->length > keep) drop_oldest(ring, ring->length - keep);
}

size_t audio_ring_pull(AudioRing *ring, int16_t *out, size_t want) {
	size_t n = ring->length < want ? ring->length : want;
	for (size_t i = 0; i < n; i++) out[i] = ring->samples[(ring->head + i) % ring->capacity];
	if (n) drop_oldest(ring, n);
	memset(out + n, 0, (want - n) * sizeof *out);
	return n;
}
