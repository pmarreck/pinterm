#ifndef PINTERM_AUDIO_PULL_H
#define PINTERM_AUDIO_PULL_H
#include <stddef.h>
#include <stdint.h>

/* Fill out[0..want) for an audio callback from a nonblocking pipe of s16
 * samples: drop the oldest queued bytes beyond want + cap (bounding latency
 * when the producer runs ahead of the audio clock), read up to want bytes in
 * whole samples, and pad the rest with silence. Returns bytes read. */
size_t audio_pull(int fd, uint8_t *out, size_t want, size_t cap);

#endif
