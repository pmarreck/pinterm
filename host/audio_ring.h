/* Bounded FIFO of s16 samples between the game thread (push) and an audio
 * device callback (pull), for hosts that play audio in-process without a pipe
 * (Windows waveOut). Callers serialize access; the ring itself is not locked. */
#ifndef PINTERM_AUDIO_RING_H
#define PINTERM_AUDIO_RING_H
#include <stddef.h>
#include <stdint.h>

typedef struct AudioRing {
	int16_t *samples; /* caller-provided storage of `capacity` samples */
	size_t capacity;
	size_t head; /* index of the oldest queued sample */
	size_t length;
} AudioRing;

void audio_ring_init(AudioRing *ring, int16_t *storage, size_t capacity);
/* Append, then drop the oldest samples so at most `keep` stay queued
 * (keep is clamped to capacity): a late device hears recent sound. */
void audio_ring_push(AudioRing *ring, const int16_t *samples, size_t count, size_t keep);
/* Fill out[0..want) from the oldest samples, padding with silence; returns
 * how many came from the ring. */
size_t audio_ring_pull(AudioRing *ring, int16_t *out, size_t want);
#endif
