//
//  BuiltinMicRingWriter.c
//  HyperVibe
//
//  Writes the built-in-mic fallback ring (SRM_BUILTIN_SHM_NAME, layout SRMSharedMemory).
//  Same single-producer discipline as the router's remote-ring writer: fill the ring
//  slots first, then publish the new monotonic frame total to writeIndex with a release
//  store, so the plug-in's acquire load can never observe an index ahead of its samples.
//
#include "BuiltinMicRingWriter.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../mic/driver/SiriRemoteMicShared.h"

static int gFileDescriptor = -1;
static SRMSharedMemory *gShared = NULL;
static uint64_t gWriteIndex = 0;
static char gLastError[256] = {0};

static void set_error(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(gLastError, sizeof(gLastError), format, arguments);
    va_end(arguments);
}

int srm_builtin_ring_open(void)
{
    if (gShared != NULL) { return 0; }

    // macOS POSIX shm objects do not support fchmod. Clear the mask only around the
    // first open so coreaudiod (a different account) can map the object read-only.
    const mode_t previousMask = umask(0);
    const int descriptor = shm_open(SRM_BUILTIN_SHM_NAME, O_CREAT | O_RDWR, 0666);
    umask(previousMask);
    if (descriptor < 0)
    {
        set_error("shm_open(%s): %s", SRM_BUILTIN_SHM_NAME, strerror(errno));
        return -1;
    }

    struct stat information = {0};
    if (fstat(descriptor, &information) != 0)
    {
        set_error("fstat(%s): %s", SRM_BUILTIN_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }
    if (information.st_size == 0)
    {
        if (ftruncate(descriptor, (off_t)sizeof(SRMSharedMemory)) != 0)
        {
            set_error("ftruncate(%s): %s", SRM_BUILTIN_SHM_NAME, strerror(errno));
            close(descriptor);
            return -1;
        }
    }
    else if (information.st_size < (off_t)sizeof(SRMSharedMemory))
    {
        set_error("shared-memory object is too small: %lld < %zu",
                  (long long)information.st_size, sizeof(SRMSharedMemory));
        close(descriptor);
        return -1;
    }

    SRMSharedMemory *shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
                                   MAP_SHARED, descriptor, 0);
    if (shared == MAP_FAILED)
    {
        set_error("mmap(%s): %s", SRM_BUILTIN_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }

    if (shared->magic == SRM_MAGIC && shared->version == SRM_VERSION &&
        shared->ringFrames == SRM_RING_FRAMES)
    {
        // A previous run already initialised this region. ADOPT its writeIndex instead of
        // resetting to 0: the plug-in may hold this exact kernel object mapped with a live
        // reader parked at the old index, and a backwards jump would underflow its
        // backlog arithmetic. Monotonic-total is the contract; keep it monotonic across
        // producer restarts too. (Never unlink/recreate, for the same reason.)
        gWriteIndex = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
        atomic_store_explicit(&shared->producerActive, 0, memory_order_release);
    }
    else
    {
        // Fresh region: publish an inactive, empty, fully-described ring.
        atomic_store_explicit(&shared->producerActive, 0, memory_order_release);
        shared->magic = SRM_MAGIC;
        shared->version = SRM_VERSION;
        shared->sampleRate = 48000;
        shared->channels = SRM_CHANNELS;
        shared->ringFrames = SRM_RING_FRAMES;
        memset(shared->ring, 0, sizeof(shared->ring));
        atomic_store_explicit(&shared->writeIndex, 0, memory_order_release);
        gWriteIndex = 0;
    }

    gFileDescriptor = descriptor;
    gShared = shared;
    gLastError[0] = '\0';
    return 0;
}

void srm_builtin_ring_set_active(int active)
{
    if (gShared != NULL)
    {
        atomic_store_explicit(&gShared->producerActive, active != 0, memory_order_release);
    }
}

int srm_builtin_ring_write(const float *samples, size_t frameCount)
{
    if (gShared == NULL || samples == NULL)
    {
        set_error("ring writer is not open");
        return -1;
    }

    for (size_t frame = 0; frame < frameCount; ++frame)
    {
        const uint64_t absoluteFrame = gWriteIndex + frame;
        gShared->ring[(uint32_t)(absoluteFrame % SRM_RING_FRAMES)] = samples[frame];
    }

    gWriteIndex += frameCount;
    atomic_store_explicit(&gShared->writeIndex, gWriteIndex, memory_order_release);
    return 0;
}

uint64_t srm_builtin_ring_write_index(void)
{
    return gWriteIndex;
}

const char *srm_builtin_ring_last_error(void)
{
    return gLastError;
}

void srm_builtin_ring_close(void)
{
    if (gShared != NULL)
    {
        atomic_store_explicit(&gShared->producerActive, 0, memory_order_release);
        munmap(gShared, sizeof(*gShared));
        gShared = NULL;
    }
    if (gFileDescriptor >= 0)
    {
        close(gFileDescriptor);
        gFileDescriptor = -1;
    }
}
