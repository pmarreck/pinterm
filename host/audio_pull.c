/* Pipe-to-callback audio reader for in-process players (CoreAudio). POSIX
 * only: the Windows host queues samples in an AudioRing instead. */
#if !defined(_WIN32)
#include "audio_pull.h"
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Read exactly n bytes that FIONREAD reported as queued, stopping early only
   on EOF or a real error. */
static size_t read_queued(int fd, uint8_t *out, size_t n) {
	size_t got = 0;
	while (got < n) {
		ssize_t r = read(fd, out + got, n - got);
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) break;
		got += (size_t)r;
	}
	return got;
}

size_t audio_pull(int fd, uint8_t *out, size_t want, size_t cap) {
	int queued = 0;
	if (ioctl(fd, FIONREAD, &queued) != 0 || queued < 0) queued = 0;
	size_t avail = (size_t)queued;
	if (avail > want + cap) {
		size_t drop = (avail - want - cap) & ~(size_t)1;
		uint8_t sink[4096];
		for (size_t left = drop; left;) {
			size_t n = left < sizeof sink ? left : sizeof sink;
			size_t r = read_queued(fd, sink, n);
			if (r < n) break;
			left -= r;
		}
		avail -= drop;
	}
	size_t take = (avail < want ? avail : want) & ~(size_t)1;
	size_t got = read_queued(fd, out, take);
	memset(out + got, 0, want - got);
	return got;
}
#endif
