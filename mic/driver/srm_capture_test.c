// M2a consumer: open "Siri Remote Mic" through CoreAudio and verify that input samples arrive.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "SiriRemoteMicShared.h"

typedef struct {
    double sumSquares;
    float peak;
    uint64_t sampleCount;
} CaptureStats;

static OSStatus capture_callback(AudioObjectID device,
                                 const AudioTimeStamp *now,
                                 const AudioBufferList *input,
                                 const AudioTimeStamp *inputTime,
                                 AudioBufferList *output,
                                 const AudioTimeStamp *outputTime,
                                 void *context)
{
    (void)device;
    (void)now;
    (void)inputTime;
    (void)output;
    (void)outputTime;

    CaptureStats *stats = context;
    if (input == NULL) { return noErr; }

    for (UInt32 bufferIndex = 0; bufferIndex < input->mNumberBuffers; ++bufferIndex)
    {
        const AudioBuffer *buffer = &input->mBuffers[bufferIndex];
        const float *samples = buffer->mData;
        const size_t count = buffer->mDataByteSize / sizeof(float);
        if (samples == NULL) { continue; }

        for (size_t sampleIndex = 0; sampleIndex < count; ++sampleIndex)
        {
            const float value = samples[sampleIndex];
            stats->sumSquares += (double)value * value;
            const float magnitude = fabsf(value);
            if (magnitude > stats->peak) { stats->peak = magnitude; }
        }
        stats->sampleCount += count;
    }
    return noErr;
}

static int copy_device_name(AudioDeviceID device, char *name, size_t capacity)
{
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress property = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) != noErr ||
        value == NULL)
    {
        return 0;
    }
    const Boolean copied = CFStringGetCString(value, name, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    return copied;
}

static AudioDeviceID find_device(const char *wantedName)
{
    AudioObjectPropertyAddress property = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &size) != noErr)
    {
        return kAudioObjectUnknown;
    }

    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) { return kAudioObjectUnknown; }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, devices) != noErr)
    {
        free(devices);
        return kAudioObjectUnknown;
    }

    AudioDeviceID match = kAudioObjectUnknown;
    const UInt32 count = size / sizeof(*devices);
    for (UInt32 index = 0; index < count; ++index)
    {
        char name[256] = {0};
        if (copy_device_name(devices[index], name, sizeof(name)) && strcmp(name, wantedName) == 0)
        {
            match = devices[index];
            break;
        }
    }
    free(devices);
    return match;
}

static void print_input_format(AudioDeviceID device)
{
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    AudioObjectPropertyAddress property = {
        kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    const OSStatus status = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &format);
    if (status != noErr)
    {
        printf("srm_capture_test: input format unavailable: %d\n", status);
        return;
    }
    char id[5] = {
        (char)(format.mFormatID >> 24),
        (char)(format.mFormatID >> 16),
        (char)(format.mFormatID >> 8),
        (char)format.mFormatID,
        '\0'
    };
    printf("srm_capture_test: format=%s flags=0x%x rate=%.0f channels=%u bits=%u bytes/frame=%u\n",
           id, format.mFormatFlags, format.mSampleRate, format.mChannelsPerFrame,
           format.mBitsPerChannel, format.mBytesPerFrame);
}

static void inspect_shared_source(void)
{
    int fd = shm_open(SRM_SHM_NAME, O_RDONLY, 0);
    if (fd < 0)
    {
        perror("srm_capture_test: shm_open");
        return;
    }
    SRMSharedMemory *shared = mmap(NULL, sizeof(*shared), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (shared == MAP_FAILED)
    {
        perror("srm_capture_test: mmap");
        return;
    }

    const uint64_t writeIndex = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
    const uint32_t sampleFrames = 480;
    double sumSquares = 0.0;
    float peak = 0.0f;
    for (uint32_t offset = 0; offset < sampleFrames; ++offset)
    {
        const uint64_t frame = writeIndex - sampleFrames + offset;
        for (uint32_t channel = 0; channel < SRM_CHANNELS; ++channel)
        {
            const float value = shared->ring[(frame % SRM_RING_FRAMES) * SRM_CHANNELS + channel];
            sumSquares += (double)value * value;
            if (fabsf(value) > peak) { peak = fabsf(value); }
        }
    }
    const double rms = sqrt(sumSquares / (sampleFrames * SRM_CHANNELS));
    printf("srm_capture_test: source write=%llu active=%u rms=%.6f peak=%.6f\n",
           (unsigned long long)writeIndex,
           atomic_load_explicit(&shared->producerActive, memory_order_acquire), rms, peak);
    munmap(shared, sizeof(*shared));
}

int main(void)
{
    inspect_shared_source();

    const AudioDeviceID device = find_device("Siri Remote Mic");
    if (device == kAudioObjectUnknown)
    {
        fprintf(stderr, "srm_capture_test: Siri Remote Mic not found\n");
        return 1;
    }
    print_input_format(device);

    CaptureStats stats = {0};
    AudioDeviceIOProcID callback = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, capture_callback, &stats, &callback);
    if (status != noErr)
    {
        fprintf(stderr, "srm_capture_test: AudioDeviceCreateIOProcID failed: %d\n", status);
        return 1;
    }

    status = AudioDeviceStart(device, callback);
    if (status != noErr)
    {
        fprintf(stderr, "srm_capture_test: AudioDeviceStart failed: %d\n", status);
        AudioDeviceDestroyIOProcID(device, callback);
        return 1;
    }

    sleep(3);
    AudioDeviceStop(device, callback);
    AudioDeviceDestroyIOProcID(device, callback);

    const double rms = stats.sampleCount == 0 ? 0.0 : sqrt(stats.sumSquares / stats.sampleCount);
    printf("srm_capture_test: samples=%llu rms=%.6f peak=%.6f\n",
           (unsigned long long)stats.sampleCount, rms, stats.peak);

    // The producer writes a 0.25-amplitude sine. Leave generous bounds for device gain controls.
    if (stats.sampleCount == 0 || rms < 0.05 || stats.peak < 0.10f)
    {
        fprintf(stderr, "srm_capture_test: FAIL — input is silent or missing\n");
        return 2;
    }
    printf("srm_capture_test: PASS — shared-memory audio reached a CoreAudio consumer\n");
    return 0;
}
