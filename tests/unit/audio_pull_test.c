/* audio_pull against a real pipe: silence padding, backlog trimming, and
 * 16-bit sample alignment. Built and run by tests/integration/audio_pull_test. */
#include "audio_pull.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures;
static void check(const char *name, int ok) {
	if (!ok) {
		failures++;
		printf("FAIL %s\n", name);
	}
}

/* Open a nonblocking pipe preloaded with bytes 1..n (wrapping at 255). */
static void loaded(int fds[2], size_t n) {
	if (pipe(fds) != 0) return;
	fcntl(fds[0], F_SETFL, O_NONBLOCK);
	for (size_t i = 0; i < n; i++) {
		uint8_t b = (uint8_t)(i % 255 + 1);
		(void)!write(fds[1], &b, 1);
	}
}

static size_t queued(int fd) {
	uint8_t sink[65536];
	ssize_t n = read(fd, sink, sizeof sink);
	return n > 0 ? (size_t)n : 0;
}

static int all_zero(const uint8_t *p, size_t n) {
	for (size_t i = 0; i < n; i++)
		if (p[i]) return 0;
	return 1;
}

int main(void) {
	uint8_t out[64];
	int fds[2];

	loaded(fds, 0);
	memset(out, 0xAA, sizeof out);
	check("empty pipe: nothing read", audio_pull(fds[0], out, 16, 32) == 0);
	check("empty pipe: buffer is silence", all_zero(out, 16));
	check("empty pipe: bytes past the request untouched", out[16] == 0xAA);
	close(fds[0]), close(fds[1]);

	loaded(fds, 6);
	memset(out, 0xAA, sizeof out);
	check("short pipe: all six bytes read", audio_pull(fds[0], out, 16, 32) == 6);
	check("short pipe: data first", out[0] == 1 && out[5] == 6);
	check("short pipe: then silence", all_zero(out + 6, 10));
	close(fds[0]), close(fds[1]);

	loaded(fds, 16);
	check("exact pipe: full buffer read", audio_pull(fds[0], out, 16, 32) == 16);
	check("exact pipe: in order", out[0] == 1 && out[15] == 16);
	check("exact pipe: nothing left", queued(fds[0]) == 0);
	close(fds[0]), close(fds[1]);

	/* 100 queued, 16 wanted, cap 32: drop the oldest 52, play the next 16,
	   leave the newest 32 queued. */
	loaded(fds, 100);
	check("backlog: plays a full buffer", audio_pull(fds[0], out, 16, 32) == 16);
	check("backlog: oldest samples dropped", out[0] == 53 && out[15] == 68);
	check("backlog: cap left queued", queued(fds[0]) == 32);
	close(fds[0]), close(fds[1]);

	/* Within the cap nothing is dropped. */
	loaded(fds, 40);
	audio_pull(fds[0], out, 16, 32);
	check("under cap: nothing dropped", out[0] == 1);
	check("under cap: rest stays queued", queued(fds[0]) == 24);
	close(fds[0]), close(fds[1]);

	/* An odd byte count is never split mid-sample. */
	loaded(fds, 5);
	memset(out, 0xAA, sizeof out);
	check("odd pipe: whole samples only", audio_pull(fds[0], out, 8, 32) == 4);
	check("odd pipe: partial sample left queued", queued(fds[0]) == 1);
	check("odd pipe: padded with silence", all_zero(out + 4, 4));
	close(fds[0]), close(fds[1]);

	/* An odd backlog trim also keeps sample alignment. */
	loaded(fds, 51);
	audio_pull(fds[0], out, 16, 32);
	check("odd backlog: trim stays sample aligned", out[0] == 3);
	close(fds[0]), close(fds[1]);

	/* A closed writer reads as silence, not an error. */
	loaded(fds, 0);
	close(fds[1]);
	check("closed pipe: silence", audio_pull(fds[0], out, 16, 32) == 0 && all_zero(out, 16));
	close(fds[0]);

	printf("%d failures\n", failures);
	return failures != 0;
}
