//
//  SiriRemoteMicRingWriter.c
//
#include "SiriRemoteMicRingWriter.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../driver/SiriRemoteMicShared.h"

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

int srm_ring_writer_open(void)
{
    if (gShared != NULL) { return 0; }

    // macOS POSIX shm objects do not support fchmod. Clear the mask only around the
    // first open so _coreaudiod can map a newly-created object read-only.
    const mode_t previousMask = umask(0);
    const int descriptor = shm_open(SRM_SHM_NAME, O_CREAT | O_RDWR, 0666);
    umask(previousMask);
    if (descriptor < 0)
    {
        set_error("shm_open(%s): %s", SRM_SHM_NAME, strerror(errno));
        return -1;
    }

    struct stat information = {0};
    if (fstat(descriptor, &information) != 0)
    {
        set_error("fstat(%s): %s", SRM_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }
    if (information.st_size == 0)
    {
        if (ftruncate(descriptor, (off_t)sizeof(SRMSharedMemory)) != 0)
        {
            set_error("ftruncate(%s): %s", SRM_SHM_NAME, strerror(errno));
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
        set_error("mmap(%s): %s", SRM_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }

    // Publish an inactive, empty, fully-described ring. Never unlink/recreate the object:
    // coreaudiod may already have this exact kernel object mapped.
    atomic_store_explicit(&shared->producerActive, 0, memory_order_release);
    shared->magic = SRM_MAGIC;
    shared->version = SRM_VERSION;
    shared->sampleRate = 48000;
    shared->channels = SRM_CHANNELS;
    shared->ringFrames = SRM_RING_FRAMES;
    memset(shared->ring, 0, sizeof(shared->ring));
    atomic_store_explicit(&shared->writeIndex, 0, memory_order_release);

    gFileDescriptor = descriptor;
    gShared = shared;
    gWriteIndex = 0;
    gLastError[0] = '\0';
    return 0;
}

void srm_ring_writer_set_active(int active)
{
    if (gShared != NULL)
    {
        atomic_store_explicit(&gShared->producerActive, active != 0, memory_order_release);
    }
}

int srm_ring_writer_write_int16(const int16_t *samples, size_t frameCount)
{
    if (gShared == NULL || samples == NULL)
    {
        set_error("ring writer is not open");
        return -1;
    }

    for (size_t frame = 0; frame < frameCount; ++frame)
    {
        const uint64_t absoluteFrame = gWriteIndex + frame;
        const uint32_t slot = (uint32_t)(absoluteFrame % SRM_RING_FRAMES);
        gShared->ring[slot] = (float)samples[frame] / 32768.0f;
    }

    gWriteIndex += frameCount;
    atomic_store_explicit(&gShared->writeIndex, gWriteIndex, memory_order_release);
    return 0;
}

uint64_t srm_ring_writer_write_index(void)
{
    return gWriteIndex;
}

const char *srm_ring_writer_last_error(void)
{
    return gLastError;
}

void srm_ring_writer_close(void)
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
    gWriteIndex = 0;
}

static void signal_cleanup(int signalNumber)
{
    if (gShared != NULL)
    {
        atomic_store_explicit(&gShared->producerActive, 0, memory_order_release);
    }
    _exit(128 + signalNumber);
}

void srm_ring_writer_install_signal_cleanup(void)
{
    struct sigaction action = {0};
    action.sa_handler = signal_cleanup;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGHUP, &action, NULL);
}
