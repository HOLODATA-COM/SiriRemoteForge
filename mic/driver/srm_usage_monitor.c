// Verify the router-side "is any app using Siri Remote Mic?" signal exposed by CoreAudio.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

static UInt32 device_is_running(AudioObjectID device)
{
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    AudioObjectPropertyAddress property = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &running) != noErr)
    {
        return UINT32_MAX;
    }
    return running;
}

static OSStatus usage_changed(AudioObjectID object,
                              UInt32 addressCount,
                              const AudioObjectPropertyAddress addresses[],
                              void *context)
{
    (void)addressCount;
    (void)addresses;
    (void)context;
    printf("srm_usage_monitor: running=%u\n", device_is_running(object));
    fflush(stdout);
    return noErr;
}

int main(void)
{
    const AudioDeviceID device = find_device("Siri Remote Mic");
    if (device == kAudioObjectUnknown)
    {
        fprintf(stderr, "srm_usage_monitor: Siri Remote Mic not found\n");
        return 1;
    }

    AudioObjectPropertyAddress property = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectAddPropertyListener(device, &property, usage_changed, NULL);
    if (status != noErr)
    {
        fprintf(stderr, "srm_usage_monitor: listener failed: %d\n", status);
        return 1;
    }

    printf("srm_usage_monitor: initial=%u\n", device_is_running(device));
    fflush(stdout);
    sleep(12);
    AudioObjectRemovePropertyListener(device, &property, usage_changed, NULL);
    printf("srm_usage_monitor: done\n");
    return 0;
}
