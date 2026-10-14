/* CoreAudio output for macOS through an AudioQueue, so the game has sound
 * where the Linux players (pw-play, paplay, aplay) do not exist. AudioToolbox
 * is loaded with dlopen and declared here from Apple's public headers, so the
 * host still cross-compiles from Linux without a macOS SDK; if loading fails
 * the game stays silent. The queue's callback thread pulls samples from the
 * same pipe the game writes to (see audio_pull). */
#include "audio_coreaudio.h"

#if defined(__APPLE__)
#include "audio_pull.h"
#include <dlfcn.h>
#include <stdint.h>
#include <unistd.h>

/* From AudioToolbox/AudioQueue.h and CoreAudioTypes/CoreAudioBaseTypes.h. */
typedef int32_t OSStatus;
typedef struct OpaqueAudioQueue *AudioQueueRef;
typedef struct AudioStreamBasicDescription {
	double mSampleRate;
	uint32_t mFormatID;
	uint32_t mFormatFlags;
	uint32_t mBytesPerPacket;
	uint32_t mFramesPerPacket;
	uint32_t mBytesPerFrame;
	uint32_t mChannelsPerFrame;
	uint32_t mBitsPerChannel;
	uint32_t mReserved;
} AudioStreamBasicDescription;
typedef struct AudioQueueBuffer {
	const uint32_t mAudioDataBytesCapacity;
	void *const mAudioData;
	uint32_t mAudioDataByteSize;
	void *mUserData;
	const uint32_t mPacketDescriptionCapacity;
	void *const mPacketDescriptions;
	uint32_t mPacketDescriptionCount;
} AudioQueueBuffer, *AudioQueueBufferRef;
typedef void (*AudioQueueOutputCallback)(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer);

enum {
	kAudioFormatLinearPCM = 0x6C70636D, /* 'lpcm' */
	kAudioFormatFlagIsSignedInteger = 1u << 2,
	kAudioFormatFlagIsPacked = 1u << 3,
};

/* Three buffers of 512 frames (about 23 ms each at 22050 Hz) keep the queue
   fed; at most CAP_BYTES more stay waiting in the pipe. */
enum { BUFFERS = 3, FRAMES_PER_BUFFER = 512, BYTES_PER_FRAME = 2, CAP_BYTES = 2048 };

static struct {
	void *lib;
	OSStatus (*new_output)(const AudioStreamBasicDescription *, AudioQueueOutputCallback, void *, void *, void *, uint32_t, AudioQueueRef *);
	OSStatus (*allocate)(AudioQueueRef, uint32_t, AudioQueueBufferRef *);
	OSStatus (*enqueue)(AudioQueueRef, AudioQueueBufferRef, uint32_t, const void *);
	OSStatus (*start)(AudioQueueRef, const void *);
	OSStatus (*stop)(AudioQueueRef, unsigned char);
	OSStatus (*dispose)(AudioQueueRef, unsigned char);
	AudioQueueRef queue;
	int fd;
} ca = {.fd = -1};

/* Refill a played buffer from the pipe (silence when the game is behind). */
static void refill(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer) {
	(void)user;
	audio_pull(ca.fd, buffer->mAudioData, buffer->mAudioDataBytesCapacity, CAP_BYTES);
	buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
	ca.enqueue(queue, buffer, 0, NULL);
}

static int load(void) {
	if (ca.lib) return 0;
	ca.lib = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY | RTLD_LOCAL);
	if (!ca.lib) return -1;
	*(void **)&ca.new_output = dlsym(ca.lib, "AudioQueueNewOutput");
	*(void **)&ca.allocate = dlsym(ca.lib, "AudioQueueAllocateBuffer");
	*(void **)&ca.enqueue = dlsym(ca.lib, "AudioQueueEnqueueBuffer");
	*(void **)&ca.start = dlsym(ca.lib, "AudioQueueStart");
	*(void **)&ca.stop = dlsym(ca.lib, "AudioQueueStop");
	*(void **)&ca.dispose = dlsym(ca.lib, "AudioQueueDispose");
	if (ca.new_output && ca.allocate && ca.enqueue && ca.start && ca.stop && ca.dispose) return 0;
	dlclose(ca.lib);
	ca.lib = NULL;
	return -1;
}

int coreaudio_start(int fd, int rate) {
	if (ca.queue || load() != 0) return -1;
	AudioStreamBasicDescription format = {
		.mSampleRate = rate,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = BYTES_PER_FRAME,
		.mFramesPerPacket = 1,
		.mBytesPerFrame = BYTES_PER_FRAME,
		.mChannelsPerFrame = 1,
		.mBitsPerChannel = 16,
	};
	ca.fd = fd;
	if (ca.new_output(&format, refill, NULL, NULL, NULL, 0, &ca.queue) != 0) {
		ca.queue = NULL;
		ca.fd = -1;
		return -1;
	}
	for (int i = 0; i < BUFFERS; i++) {
		AudioQueueBufferRef buffer;
		if (ca.allocate(ca.queue, FRAMES_PER_BUFFER * BYTES_PER_FRAME, &buffer) != 0) goto fail;
		refill(NULL, ca.queue, buffer);
	}
	if (ca.start(ca.queue, NULL) == 0) return 0;
fail:
	ca.dispose(ca.queue, 1);
	ca.queue = NULL;
	ca.fd = -1;
	return -1;
}

void coreaudio_stop(void) {
	if (!ca.queue) return;
	ca.stop(ca.queue, 1);
	ca.dispose(ca.queue, 1);
	ca.queue = NULL;
	close(ca.fd);
	ca.fd = -1;
}

#else

int coreaudio_start(int fd, int rate) {
	(void)fd;
	(void)rate;
	return -1;
}

void coreaudio_stop(void) {}

#endif
