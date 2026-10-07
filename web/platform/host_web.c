/* Freestanding WebAssembly host for the browser build. JavaScript writes a
 * tick packet into the shared input buffer, calls web_frame(), then copies the
 * frame bytes, PCM samples and log lines out through the exported pointers.
 * Includes a small power-of-two free-list allocator for Roc. */
#include "roc_platform_abi.h"

#define PAGE 65536u
#define MIN_CLASS 4u  /* 16 bytes */
#define MAX_CLASS 31u
#define HEADER 16u    /* keeps payload 16-byte aligned */
#define INPUT_CAPACITY (13u + 8192u)

extern unsigned char __heap_base;
static uintptr_t heap_next;
static void *free_lists[MAX_CLASS + 1];

void roc_panic_js(const uint8_t *bytes, size_t len) __attribute__((import_module("env"), import_name("roc_panic")));
void roc_dbg_js(const uint8_t *bytes, size_t len) __attribute__((import_module("env"), import_name("roc_dbg")));

static void *grow(size_t bytes) {
	if (!heap_next) heap_next = ((uintptr_t)&__heap_base + 15u) & ~(uintptr_t)15u;
	uintptr_t start = heap_next;
	uintptr_t end = start + bytes;
	uintptr_t have = (uintptr_t)__builtin_wasm_memory_size(0) * PAGE;
	if (end > have) {
		size_t pages = (size_t)((end - have + PAGE - 1) / PAGE);
		if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) __builtin_trap();
	}
	heap_next = end;
	return (void *)start;
}

static unsigned class_for(size_t total) {
	unsigned c = MIN_CLASS;
	while (((size_t)1 << c) < total) {
		if (++c > MAX_CLASS) __builtin_trap();
	}
	return c;
}

void *roc_alloc(size_t length, size_t alignment) {
	if (alignment > HEADER) __builtin_trap();
	unsigned c = class_for(length + HEADER);
	uint8_t *block = free_lists[c];
	if (block) free_lists[c] = *(void **)block;
	else block = grow((size_t)1 << c);
	*(uint32_t *)block = c;
	return block + HEADER;
}

void roc_dealloc(void *ptr, size_t alignment) {
	(void)alignment;
	if (!ptr) return;
	uint8_t *block = (uint8_t *)ptr - HEADER;
	unsigned c = *(uint32_t *)block;
	*(void **)block = free_lists[c];
	free_lists[c] = block;
}

void *roc_realloc(void *ptr, size_t length, size_t alignment) {
	if (!ptr) return roc_alloc(length, alignment);
	uint8_t *block = (uint8_t *)ptr - HEADER;
	size_t old = ((size_t)1 << *(uint32_t *)block) - HEADER;
	if (length <= old) return ptr;
	uint8_t *fresh = roc_alloc(length, alignment);
	__builtin_memcpy(fresh, ptr, old);
	roc_dealloc(ptr, alignment);
	return fresh;
}

void roc_dbg(const uint8_t *bytes, size_t len) { roc_dbg_js(bytes, len); }
void roc_expect_failed(const uint8_t *bytes, size_t len) { roc_dbg_js(bytes, len); }
void roc_crashed(const uint8_t *bytes, size_t len) {
	roc_panic_js(bytes, len);
	__builtin_trap();
}

static uint8_t input[INPUT_CAPACITY];
static RocBox model;
/* The frame result is an anonymous glue struct; name it by the call type. */
static __typeof__(pinterm_web_frame((RocBox)0, (RocList){0})) last;
static int have_last;

static void release_last(void) {
	if (!have_last) return;
	(void)pinterm_web_release(last.bytes, last.samples, last.log);
	have_last = 0;
}

__attribute__((export_name("web_input"))) uint8_t *web_input(void) { return input; }

/* Config: `count` little-endian i64 values previously written to web_input(). */
__attribute__((export_name("web_init"))) void web_init(uint32_t count) {
	if (count * 8u > INPUT_CAPACITY) __builtin_trap();
	RocList cfg = pinterm_web_i64s(count);
	__builtin_memcpy(cfg.elements, input, count * 8u);
	release_last();
	model = pinterm_web_init(cfg);
}

/* Tick packet of `length` bytes previously written to web_input(). */
__attribute__((export_name("web_frame"))) void web_frame(uint32_t length) {
	if (length > INPUT_CAPACITY) __builtin_trap();
	RocList packet = pinterm_web_bytes(length);
	__builtin_memcpy(packet.elements, input, length);
	release_last();
	last = pinterm_web_frame(model, packet);
	model = last.model;
	have_last = 1;
}

__attribute__((export_name("web_bytes_ptr"))) void *web_bytes_ptr(void) { return last.bytes.elements; }
__attribute__((export_name("web_bytes_len"))) uint32_t web_bytes_len(void) { return (uint32_t)last.bytes.length; }
__attribute__((export_name("web_samples_ptr"))) void *web_samples_ptr(void) { return last.samples.elements; }
__attribute__((export_name("web_samples_len"))) uint32_t web_samples_len(void) { return (uint32_t)last.samples.length; }
__attribute__((export_name("web_log_ptr"))) void *web_log_ptr(void) { return last.log.elements; }
__attribute__((export_name("web_log_len"))) uint32_t web_log_len(void) { return (uint32_t)last.log.length; }
__attribute__((export_name("web_quit"))) uint32_t web_quit(void) { return last.quit; }
