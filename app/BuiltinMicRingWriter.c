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
#include <math.h>
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
static _Atomic uint32_t gMeterPowerBits = 0;
static int gRemoteMeterFileDescriptor = -1;
static const SRMSharedMemory *gRemoteMeterShared = NULL;

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

void srm_builtin_meter_store_power(float meanSquarePower)
{
    uint32_t bits = 0;
    memcpy(&bits, &meanSquarePower, sizeof(bits));
    atomic_store_explicit(&gMeterPowerBits, bits, memory_order_relaxed);
}

float srm_builtin_meter_load_power(void)
{
    const uint32_t bits = atomic_load_explicit(&gMeterPowerBits, memory_order_relaxed);
    float meanSquarePower = 0.0f;
    memcpy(&meanSquarePower, &bits, sizeof(meanSquarePower));
    return meanSquarePower;
}

enum
{
    SRM_METER_POWER_FRAMES = 960,        // 20 ms at 48 kHz
    SRM_METER_ANALYSIS_FRAMES = 1920,    // 40 ms: enough for low speech fundamentals
    SRM_METER_DECIMATION = 6,
    SRM_METER_ANALYSIS_RATE = 8000,
    SRM_METER_DOWNSAMPLED_FRAMES = SRM_METER_ANALYSIS_FRAMES / SRM_METER_DECIMATION,
    SRM_METER_MIN_LAG = SRM_METER_ANALYSIS_RATE / 400,
    SRM_METER_MAX_LAG = SRM_METER_ANALYSIS_RATE / 75
};

static float clamp01(float value)
{
    if (value < 0.0f) { return 0.0f; }
    if (value > 1.0f) { return 1.0f; }
    return value;
}

static void clear_meter_features(SRMMeterFeatures *features)
{
    features->meanSquarePower = 0.0f;
    features->pitchHz = 0.0f;
    features->pitchConfidence = 0.0f;
    features->brightness = 0.0f;
}

static int valid_meter_ring(const SRMSharedMemory *shared)
{
    return shared != NULL &&
           shared->magic == SRM_MAGIC && shared->version == SRM_VERSION &&
           shared->sampleRate == 48000 && shared->channels == SRM_CHANNELS &&
           shared->ringFrames == SRM_RING_FRAMES;
}

// YIN-style pitch tracking on a box-filtered 8 kHz view of the recent PCM. The complete
// calculation is roughly 35k multiply-adds per 30 Hz snapshot and runs on the feeder queue,
// never the audio callback. A derivative-energy ratio supplies a cheap spectral-brightness
// estimate: vowels stay restrained while crisp consonants light the bar caps.
static void analyse_meter_window(const SRMSharedMemory *shared,
                                 uint64_t writeIndex,
                                 SRMMeterFeatures *features)
{
    clear_meter_features(features);
    if (writeIndex == 0) { return; }

    const uint64_t powerFrames = writeIndex < SRM_METER_POWER_FRAMES
        ? writeIndex : SRM_METER_POWER_FRAMES;
    const uint64_t powerFirst = writeIndex - powerFrames;
    double sumSquares = 0.0;
    for (uint64_t frame = powerFirst; frame < writeIndex; ++frame)
    {
        const float sample = shared->ring[(uint32_t)(frame % SRM_RING_FRAMES)];
        sumSquares += (double)sample * (double)sample;
    }
    features->meanSquarePower = powerFrames == 0
        ? 0.0f : (float)(sumSquares / (double)powerFrames);

    uint64_t rawFrames = writeIndex < SRM_METER_ANALYSIS_FRAMES
        ? writeIndex : SRM_METER_ANALYSIS_FRAMES;
    rawFrames -= rawFrames % SRM_METER_DECIMATION;
    const size_t sampleCount = (size_t)(rawFrames / SRM_METER_DECIMATION);
    if (sampleCount <= (size_t)(SRM_METER_MAX_LAG + 24)) { return; }

    float samples[SRM_METER_DOWNSAMPLED_FRAMES] = {0};
    const uint64_t firstFrame = writeIndex - rawFrames;
    double mean = 0.0;
    for (size_t sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex)
    {
        double sum = 0.0;
        const uint64_t groupFirst = firstFrame + sampleIndex * SRM_METER_DECIMATION;
        for (uint64_t offset = 0; offset < SRM_METER_DECIMATION; ++offset)
        {
            sum += shared->ring[(uint32_t)((groupFirst + offset) % SRM_RING_FRAMES)];
        }
        samples[sampleIndex] = (float)(sum / SRM_METER_DECIMATION);
        mean += samples[sampleIndex];
    }
    mean /= (double)sampleCount;

    double signalEnergy = 0.0;
    double derivativeEnergy = 0.0;
    float previous = 0.0f;
    for (size_t index = 0; index < sampleCount; ++index)
    {
        samples[index] -= (float)mean;
        const double value = samples[index];
        signalEnergy += value * value;
        if (index != 0)
        {
            const double delta = value - previous;
            derivativeEnergy += delta * delta;
        }
        previous = samples[index];
    }
    if (signalEnergy <= 1.0e-12) { return; }

    const float spectralSlope = (float)sqrt(derivativeEnergy / signalEnergy);
    features->brightness = clamp01((spectralSlope - 0.08f) / 0.72f);

    float normalisedDifference[SRM_METER_MAX_LAG + 1] = {0};
    const size_t comparisonCount = sampleCount - SRM_METER_MAX_LAG;
    double runningDifference = 0.0;
    normalisedDifference[0] = 1.0f;
    for (int lag = 1; lag <= SRM_METER_MAX_LAG; ++lag)
    {
        double sum = 0.0;
        for (size_t index = 0; index < comparisonCount; ++index)
        {
            const double delta = (double)samples[index] - samples[index + (size_t)lag];
            sum += delta * delta;
        }
        runningDifference += sum;
        normalisedDifference[lag] = runningDifference <= 1.0e-20
            ? 1.0f : (float)(sum * lag / runningDifference);
    }

    int candidate = 0;
    int bestLag = SRM_METER_MIN_LAG;
    float bestScore = normalisedDifference[bestLag];
    for (int lag = SRM_METER_MIN_LAG; lag <= SRM_METER_MAX_LAG; ++lag)
    {
        const float score = normalisedDifference[lag];
        if (score < bestScore)
        {
            bestScore = score;
            bestLag = lag;
        }
        if (score < 0.20f)
        {
            candidate = lag;
            while (candidate < SRM_METER_MAX_LAG &&
                   normalisedDifference[candidate + 1] < normalisedDifference[candidate])
            {
                ++candidate;
            }
            break;
        }
    }
    if (candidate == 0 && bestScore < 0.30f) { candidate = bestLag; }
    if (candidate == 0) { return; }

    const float confidence = clamp01(1.0f - normalisedDifference[candidate]);
    features->pitchConfidence = confidence;
    if (confidence < 0.58f) { return; }

    float refinedLag = (float)candidate;
    if (candidate > SRM_METER_MIN_LAG && candidate < SRM_METER_MAX_LAG)
    {
        const float left = normalisedDifference[candidate - 1];
        const float centre = normalisedDifference[candidate];
        const float right = normalisedDifference[candidate + 1];
        const float denominator = left - 2.0f * centre + right;
        if (fabsf(denominator) > 1.0e-6f)
        {
            float adjustment = 0.5f * (left - right) / denominator;
            if (adjustment < -0.5f) { adjustment = -0.5f; }
            if (adjustment > 0.5f) { adjustment = 0.5f; }
            refinedLag += adjustment;
        }
    }
    const float pitch = SRM_METER_ANALYSIS_RATE / refinedLag;
    if (isfinite(pitch) && pitch >= 75.0f && pitch <= 400.0f)
    {
        features->pitchHz = pitch;
    }
}

static int snapshot_meter_ring(const SRMSharedMemory *shared,
                               SRMMeterFeatures *features,
                               uint64_t *writeIndex,
                               uint32_t *producerActive)
{
    if (features == NULL || writeIndex == NULL || producerActive == NULL) { return -1; }
    clear_meter_features(features);
    *writeIndex = 0;
    *producerActive = 0;
    if (!valid_meter_ring(shared)) { return -1; }

    const uint32_t active = atomic_load_explicit(&shared->producerActive,
                                                  memory_order_acquire);
    const uint64_t index = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
    *producerActive = active;
    *writeIndex = index;
    if (active != 0 && index != 0) { analyse_meter_window(shared, index, features); }
    return 0;
}

int srm_builtin_meter_snapshot(SRMMeterFeatures *features,
                               uint64_t *writeIndex,
                               uint32_t *producerActive)
{
    return snapshot_meter_ring(gShared, features, writeIndex, producerActive);
}

static int open_remote_meter(void)
{
    if (gRemoteMeterShared != NULL) { return 0; }

    const int descriptor = shm_open(SRM_SHM_NAME, O_RDONLY, 0);
    if (descriptor < 0) { return -1; }

    struct stat information = {0};
    if (fstat(descriptor, &information) != 0 ||
        information.st_size < (off_t)sizeof(SRMSharedMemory))
    {
        close(descriptor);
        return -1;
    }

    const SRMSharedMemory *shared = mmap(NULL, sizeof(*shared), PROT_READ,
                                         MAP_SHARED, descriptor, 0);
    if (shared == MAP_FAILED)
    {
        close(descriptor);
        return -1;
    }

    gRemoteMeterFileDescriptor = descriptor;
    gRemoteMeterShared = shared;
    return 0;
}

int srm_remote_meter_snapshot(SRMMeterFeatures *features,
                              uint64_t *writeIndex,
                              uint32_t *producerActive)
{
    if (features == NULL || writeIndex == NULL || producerActive == NULL)
    {
        return -1;
    }
    clear_meter_features(features);
    *writeIndex = 0;
    *producerActive = 0;

    if (open_remote_meter() != 0) { return -1; }
    return snapshot_meter_ring(gRemoteMeterShared, features, writeIndex, producerActive);
}

static int audio_state(const SRMSharedMemory *shared,
                       uint64_t *writeIndex,
                       uint32_t *producerActive)
{
    if (writeIndex == NULL || producerActive == NULL || !valid_meter_ring(shared))
    {
        return -1;
    }
    *producerActive = atomic_load_explicit(&shared->producerActive, memory_order_acquire);
    *writeIndex = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
    return 0;
}

static size_t audio_read(const SRMSharedMemory *shared,
                         uint64_t *cursor,
                         float *samples,
                         size_t capacity,
                         uint32_t *producerActive)
{
    if (cursor == NULL || samples == NULL || producerActive == NULL || capacity == 0 ||
        !valid_meter_ring(shared))
    {
        return 0;
    }

    const uint32_t active = atomic_load_explicit(&shared->producerActive, memory_order_acquire);
    const uint64_t published = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
    *producerActive = active;

    // A producer restart or an overrun must never turn subtraction into an enormous unsigned
    // backlog. Retain the newest ringful: it is the only audio that physically still exists.
    if (*cursor > published) { *cursor = published; }
    if (published - *cursor > SRM_RING_FRAMES) {
        *cursor = published - SRM_RING_FRAMES;
    }

    uint64_t available = published - *cursor;
    if (available > capacity) { available = capacity; }
    for (uint64_t frame = 0; frame < available; ++frame) {
        samples[frame] = shared->ring[(uint32_t)((*cursor + frame) % SRM_RING_FRAMES)];
    }
    *cursor += available;
    return (size_t)available;
}

int srm_builtin_audio_state(uint64_t *writeIndex, uint32_t *producerActive)
{
    return audio_state(gShared, writeIndex, producerActive);
}

int srm_remote_audio_state(uint64_t *writeIndex, uint32_t *producerActive)
{
    if (open_remote_meter() != 0) { return -1; }
    return audio_state(gRemoteMeterShared, writeIndex, producerActive);
}

size_t srm_builtin_audio_read(uint64_t *cursor, float *samples, size_t capacity,
                              uint32_t *producerActive)
{
    return audio_read(gShared, cursor, samples, capacity, producerActive);
}

size_t srm_remote_audio_read(uint64_t *cursor, float *samples, size_t capacity,
                             uint32_t *producerActive)
{
    if (open_remote_meter() != 0) { return 0; }
    return audio_read(gRemoteMeterShared, cursor, samples, capacity, producerActive);
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
    if (gRemoteMeterShared != NULL)
    {
        munmap((void *)gRemoteMeterShared, sizeof(*gRemoteMeterShared));
        gRemoteMeterShared = NULL;
    }
    if (gRemoteMeterFileDescriptor >= 0)
    {
        close(gRemoteMeterFileDescriptor);
        gRemoteMeterFileDescriptor = -1;
    }
}
