/* Roc platform ABI shim: allocation hooks plus hosted functions that forward
 * to the native frontend adapter declared in pinterm_host.h. */
#include "roc_platform_abi.h"
#include "pinterm_host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *roc_alloc(size_t length, size_t alignment) {
	if (alignment < sizeof(void *)) alignment = sizeof(void *);
	size_t rounded = (length + alignment - 1) / alignment * alignment;
	void *p = aligned_alloc(alignment, rounded ? rounded : alignment);
	if (!p) {
		fputs("pinterm: out of memory\n", stderr);
		abort();
	}
	return p;
}

void roc_dealloc(void *ptr, size_t alignment) {
	(void)alignment;
	free(ptr);
}

void *roc_realloc(void *ptr, size_t length, size_t alignment) {
	/* malloc/realloc guarantee 16-byte alignment on supported targets; Roc's
	 * largest scalar alignment (Dec, I128) is 16. */
	if (alignment > 16) {
		fputs("pinterm: unsupported realloc alignment\n", stderr);
		abort();
	}
	void *p = realloc(ptr, length ? length : 1);
	if (!p) {
		fputs("pinterm: out of memory\n", stderr);
		abort();
	}
	return p;
}

void roc_dbg(const uint8_t *bytes, size_t count) { fwrite(bytes, 1, count, stderr); fputc('\n', stderr); }
void roc_expect_failed(const uint8_t *bytes, size_t count) { fwrite(bytes, 1, count, stderr); fputc('\n', stderr); }
void roc_crashed(const uint8_t *bytes, size_t count) {
	fwrite(bytes, 1, count, stderr);
	fputc('\n', stderr);
	abort();
}

RocList pinterm_host_config(void) {
	int64_t values[PT_CFG_COUNT] = {0};
	pt_config(values);
	RocList list = pinterm_owned_i64(PT_CFG_COUNT);
	memcpy(list.elements, values, sizeof values);
	return list;
}

/* Ownership of the argument returns to Roc with the result, which then drops it. */
RocList pinterm_host_present(RocList bytes) {
	pt_present(bytes.elements, bytes.length);
	return bytes;
}

RocList pinterm_host_audio(RocList samples) {
	pt_audio(samples.elements, samples.length);
	return samples;
}

RocList pinterm_host_tick(void) {
	uint8_t packet[PT_TICK_HEADER + PT_TICK_MAX_INPUT];
	size_t n = pt_tick(packet, sizeof packet);
	RocList list = pinterm_owned_bytes(n);
	memcpy(list.elements, packet, n);
	return list;
}

RocList pinterm_host_log(RocList bytes) {
	pt_log(bytes.elements, bytes.length);
	return bytes;
}

void pinterm_host_control(uint8_t code) { pt_control(code); }
