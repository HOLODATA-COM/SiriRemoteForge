// Standalone M2a producer for the Siri Remote Mic shared-memory ring.
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "SiriRemoteMicShared.h"

enum { kSampleRate = 48000, kChunkFrames = 480, kRunSeconds = 300 };
static volatile sig_atomic_t gKeepRunning = 1;

static void stop_writer(int signal_number)
{
    (void)signal_number;
    gKeepRunning = 0;
}

int main(void)
{
    // Temporarily clear umask on first creation because macOS POSIX shm objects reject fchmod().
    // Never unlink here: an already-running plug-in may have this exact kernel object mapped.
    const mode_t previous_mask = umask(0);
    int fd = shm_open(SRM_SHM_NAME, O_CREAT | O_RDWR, 0666);
    umask(previous_mask);
    if (fd < 0) { perror("shm_open"); return 1; }
    struct stat info = {0};
    if (fstat(fd, &info) != 0) { perror("fstat"); close(fd); return 1; }
    if (info.st_size == 0)
    {
        if (ftruncate(fd, (off_t)sizeof(SRMSharedMemory)) != 0) { perror("ftruncate"); close(fd); return 1; }
    }
    else if (info.st_size < (off_t)sizeof(SRMSharedMemory))
    {
        fprintf(stderr, "unexpected shared-memory size: %lld\n", (long long)info.st_size);
        close(fd);
        return 1;
    }

    SRMSharedMemory *shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    atomic_store_explicit(&shared->producerActive, 0, memory_order_release);
    shared->magic = SRM_MAGIC;
    shared->version = SRM_VERSION;
    shared->sampleRate = kSampleRate;
    shared->channels = SRM_CHANNELS;
    shared->ringFrames = SRM_RING_FRAMES;
    memset(shared->ring, 0, sizeof(shared->ring));
    atomic_store_explicit(&shared->writeIndex, 0, memory_order_release);
    atomic_store_explicit(&shared->producerActive, 1, memory_order_release);

    signal(SIGINT, stop_writer);
    signal(SIGTERM, stop_writer);
    printf("srm_test_writer: writing 440 Hz mono tone to %s for about %d seconds\n", SRM_SHM_NAME, kRunSeconds);

    const float phase_step = 2.0f * (float)M_PI * 440.0f / (float)kSampleRate;
    float phase = 0.0f;
    const struct timespec pause = { .tv_sec = 0, .tv_nsec = 10 * 1000 * 1000 };
    uint64_t write_index = 0;

    for (unsigned chunk = 0; gKeepRunning && chunk < kRunSeconds * 100; ++chunk)
    {
        for (uint32_t frame = 0; frame < kChunkFrames; ++frame)
        {
            const uint32_t slot = (uint32_t)((write_index + frame) % SRM_RING_FRAMES);
            const float sample = 0.25f * sinf(phase);
            for (uint32_t channel = 0; channel < SRM_CHANNELS; ++channel)
            {
                shared->ring[(size_t)slot * SRM_CHANNELS + channel] = sample;
            }
            phase += phase_step;
            if (phase >= 2.0f * (float)M_PI) { phase -= 2.0f * (float)M_PI; }
        }
        write_index += kChunkFrames;
        atomic_store_explicit(&shared->writeIndex, write_index, memory_order_release);
        if ((chunk + 1) % 100 == 0) { printf("srm_test_writer: %u s written\n", (chunk + 1) / 100); fflush(stdout); }
        while (nanosleep(&pause, NULL) != 0 && errno == EINTR && gKeepRunning) { }
    }

    atomic_store_explicit(&shared->producerActive, 0, memory_order_release);
    printf("srm_test_writer: stopped\n");
    munmap(shared, sizeof(*shared));
    close(fd);
    return 0;
}
