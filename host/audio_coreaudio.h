#ifndef PINTERM_AUDIO_COREAUDIO_H
#define PINTERM_AUDIO_COREAUDIO_H

/* Play s16 mono PCM at `rate` Hz from the nonblocking pipe read end `fd`
 * through a CoreAudio output queue. Returns 0 when playing (the queue owns
 * fd until coreaudio_stop), -1 when CoreAudio is unavailable (every non-Apple
 * build, or a failed queue on macOS). */
int coreaudio_start(int fd, int rate);

/* Stop and dispose of the queue started by coreaudio_start, then close fd. */
void coreaudio_stop(void);

#endif
