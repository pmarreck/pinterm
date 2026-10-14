/* Roc platform ABI shim: allocation hooks plus hosted functions that forward
 * to the native frontend adapter declared in pinterm_host.h. */
#include "roc_platform_abi.h"
#include "pinterm_host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
/* MinGW has no C11 aligned_alloc; its aligned heap needs the matching
   realloc and free. MSVC-ABI objects (the Roc core on Windows) that use
   floating point also reference the CRT marker _fltused. */
#include <malloc.h>
#define pinterm_aligned_alloc(alignment, size) _aligned_malloc((size), (alignment))
#define pinterm_aligned_realloc(ptr, size) _aligned_realloc((ptr), (size), 16)
#define pinterm_aligned_free(ptr) _aligned_free(ptr)
int _fltused = 0;
#else
#define pinterm_aligned_alloc(alignment, size) aligned_alloc((alignment), (size))
#define pinterm_aligned_realloc(ptr, size) realloc((ptr), (size))
#define pinterm_aligned_free(ptr) free(ptr)
#endif

void *roc_alloc(size_t length, size_t alignment) {
	if (alignment < sizeof(void *)) alignment = sizeof(void *);
	size_t rounded = (length + alignment - 1) / alignment * alignment;
	void *p = pinterm_aligned_alloc(alignment, rounded ? rounded : alignment);
	if (!p) {
		fputs("pinterm: out of memory\n", stderr);
		abort();
	}
	return p;
}

void roc_dealloc(void *ptr, size_t alignment) {
	(void)alignment;
	pinterm_aligned_free(ptr);
}

void *roc_realloc(void *ptr, size_t length, size_t alignment) {
	/* malloc/realloc guarantee 16-byte alignment on supported targets; Roc's
	 * largest scalar alignment (Dec, I128) is 16. */
	if (alignment > 16) {
		fputs("pinterm: unsupported realloc alignment\n", stderr);
		abort();
	}
	void *p = pinterm_aligned_realloc(ptr, length ? length : 1);
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

RocList pinterm_host_load_scores(void) {
	static uint8_t buf[PT_SCORES_MAX];
	size_t n = pt_load_scores(buf, sizeof buf);
	RocList list = pinterm_owned_bytes(n);
	if (n) memcpy(list.elements, buf, n);
	return list;
}

RocList pinterm_host_save_scores(RocList bytes) {
	pt_save_scores(bytes.elements, bytes.length);
	return bytes;
}
