#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *copy_string_property(AudioDeviceID device, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress property = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) != noErr || value == NULL)
    {
        return NULL;
    }

    const CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
                                                               kCFStringEncodingUTF8) + 1;
    char *result = calloc((size_t)capacity, 1);
    if (result == NULL || !CFStringGetCString(value, result, capacity, kCFStringEncodingUTF8))
    {
        free(result);
        result = NULL;
    }
    CFRelease(value);
    return result;
}

static int has_input_streams(AudioDeviceID device)
{
    AudioObjectPropertyAddress property = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size) == noErr && size > 0;
}

static UInt32 copy_u32_property(AudioDeviceID device, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress property = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) != noErr)
    {
        return 0;
    }
    return value;
}

static Float64 copy_f64_property(AudioDeviceID device, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress property = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 value = 0;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) != noErr)
    {
        return 0;
    }
    return value;
}

static void format_fourcc(UInt32 value, char output[5])
{
    output[0] = (char)((value >> 24) & 0xff);
    output[1] = (char)((value >> 16) & 0xff);
    output[2] = (char)((value >> 8) & 0xff);
    output[3] = (char)(value & 0xff);
    output[4] = '\0';
    for (int index = 0; index < 4; ++index)
    {
        if (!isprint((unsigned char)output[index]))
        {
            output[index] = '?';
        }
    }
}

int main(void)
{
    AudioObjectPropertyAddress property = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                      &property, 0, NULL, &size);
    if (status != noErr || size == 0)
    {
        fprintf(stderr, "AudioInputProbe: cannot enumerate devices (status=%d)\n", (int)status);
        return EXIT_FAILURE;
    }

    AudioDeviceID *devices = calloc(1, size);
    if (devices == NULL)
    {
        fprintf(stderr, "AudioInputProbe: allocation failed\n");
        return EXIT_FAILURE;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, devices);
    if (status != noErr)
    {
        fprintf(stderr, "AudioInputProbe: device query failed (status=%d)\n", (int)status);
        free(devices);
        return EXIT_FAILURE;
    }

    const UInt32 deviceCount = size / sizeof(*devices);
    UInt32 inputCount = 0;
    printf("HyperVibe AudioInputProbe\n");
    printf("CoreAudio devices=%u\n", deviceCount);

    for (UInt32 index = 0; index < deviceCount; ++index)
    {
        const AudioDeviceID device = devices[index];
        if (!has_input_streams(device)) { continue; }
        ++inputCount;

        char *name = copy_string_property(device, kAudioObjectPropertyName);
        char *uid = copy_string_property(device, kAudioDevicePropertyDeviceUID);
        char *manufacturer = copy_string_property(device, kAudioObjectPropertyManufacturer);
        const UInt32 transport = copy_u32_property(device, kAudioDevicePropertyTransportType);
        const Float64 rate = copy_f64_property(device, kAudioDevicePropertyNominalSampleRate);
        char fourcc[5];
        format_fourcc(transport, fourcc);

        printf("input[%u] id=%u name=%s\n", inputCount, device, name != NULL ? name : "(unknown)");
        printf("  uid=%s\n", uid != NULL ? uid : "(unknown)");
        printf("  manufacturer=%s transport=%s/0x%08x nominalRate=%.0f\n",
               manufacturer != NULL ? manufacturer : "(unknown)", fourcc, transport, rate);

        free(name);
        free(uid);
        free(manufacturer);
    }

    free(devices);
    printf("AudioInputProbe complete; publicInputDevices=%u\n", inputCount);
    return EXIT_SUCCESS;
}
