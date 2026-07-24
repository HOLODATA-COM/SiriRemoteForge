//
//  srm_driver_contract_test.c
//
//  Loads the HAL bundle into this test process and exercises its AudioServerPlugIn
//  interface with a fake host. Nothing is installed and coreaudiod is never contacted.
//
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Input = 4,
    kObjectID_Volume_Input_Master = 5,
    kObjectID_Mute_Input_Master = 6,
    kObjectID_Stream_Output = 7,
    kObjectID_Volume_Output_Master = 8,
    kObjectID_Mute_Output_Master = 9,
    kObjectID_Pitch_Adjust = 10,
    kObjectID_ClockSource = 11,
    kObjectID_Device2 = 12
};

static unsigned gFailures = 0;
static unsigned gUnexpectedNotifications = 0;

#define CHECK(condition, ...) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "contract test: FAIL: "); \
            fprintf(stderr, __VA_ARGS__); \
            fputc('\n', stderr); \
            ++gFailures; \
        } \
    } while (0)

static OSStatus host_properties_changed(AudioServerPlugInHostRef host,
                                        AudioObjectID objectID,
                                        UInt32 addressCount,
                                        const AudioObjectPropertyAddress *addresses)
{
    (void)host;
    (void)objectID;
    (void)addressCount;
    (void)addresses;
    ++gUnexpectedNotifications;
    return noErr;
}

static OSStatus host_copy_from_storage(AudioServerPlugInHostRef host,
                                       CFStringRef key,
                                       CFPropertyListRef *data)
{
    (void)host;
    (void)key;
    *data = NULL;
    return noErr;
}

static OSStatus host_write_to_storage(AudioServerPlugInHostRef host,
                                      CFStringRef key,
                                      CFPropertyListRef data)
{
    (void)host;
    (void)key;
    (void)data;
    return noErr;
}

static OSStatus host_delete_from_storage(AudioServerPlugInHostRef host, CFStringRef key)
{
    (void)host;
    (void)key;
    return noErr;
}

static OSStatus host_request_configuration_change(AudioServerPlugInHostRef host,
                                                  AudioObjectID device,
                                                  UInt64 action,
                                                  void *information)
{
    (void)host;
    (void)device;
    (void)action;
    (void)information;
    return noErr;
}

static const AudioServerPlugInHostInterface kFakeHost = {
    host_properties_changed,
    host_copy_from_storage,
    host_write_to_storage,
    host_delete_from_storage,
    host_request_configuration_change
};

static UInt32 property_size(AudioServerPlugInDriverRef driver,
                            AudioObjectID objectID,
                            AudioObjectPropertySelector selector,
                            AudioObjectPropertyScope scope)
{
    const AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = UINT32_MAX;
    const OSStatus status = (*driver)->GetPropertyDataSize(
        driver, objectID, 0, &address, 0, NULL, &size);
    CHECK(status == noErr, "GetPropertyDataSize object=%u selector=0x%x status=%d",
          objectID, selector, status);
    return status == noErr ? size : 0;
}

static UInt32 object_list(AudioServerPlugInDriverRef driver,
                          AudioObjectID objectID,
                          AudioObjectPropertySelector selector,
                          AudioObjectPropertyScope scope,
                          AudioObjectID *objects,
                          UInt32 capacity)
{
    const AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    const UInt32 advertisedSize = property_size(driver, objectID, selector, scope);
    UInt32 returnedSize = 0;
    memset(objects, 0xA5, capacity * sizeof(*objects));
    const OSStatus status = (*driver)->GetPropertyData(
        driver, objectID, 0, &address, 0, NULL,
        capacity * (UInt32)sizeof(*objects), &returnedSize, objects);
    CHECK(status == noErr, "GetPropertyData list object=%u selector=0x%x status=%d",
          objectID, selector, status);
    CHECK(returnedSize == advertisedSize,
          "size mismatch object=%u selector=0x%x advertised=%u returned=%u",
          objectID, selector, advertisedSize, returnedSize);
    CHECK(returnedSize <= capacity * sizeof(*objects),
          "list overflow object=%u selector=0x%x returned=%u capacity=%u",
          objectID, selector, returnedSize, capacity);
    return returnedSize / (UInt32)sizeof(*objects);
}

static AudioObjectID object_owner(AudioServerPlugInDriverRef driver, AudioObjectID objectID)
{
    const AudioObjectPropertyAddress address = {
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID owner = UINT32_MAX;
    UInt32 returnedSize = 0;
    const OSStatus status = (*driver)->GetPropertyData(
        driver, objectID, 0, &address, 0, NULL,
        sizeof(owner), &returnedSize, &owner);
    CHECK(status == noErr && returnedSize == sizeof(owner),
          "owner query object=%u status=%d size=%u", objectID, status, returnedSize);
    return owner;
}

static Boolean has_property(AudioServerPlugInDriverRef driver,
                            AudioObjectID objectID,
                            AudioObjectPropertySelector selector,
                            AudioObjectPropertyScope scope)
{
    const AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    return (*driver)->HasProperty(driver, objectID, 0, &address);
}

static UInt32 uint32_property(AudioServerPlugInDriverRef driver,
                              AudioObjectID objectID,
                              AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope)
{
    const AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 value = UINT32_MAX;
    UInt32 returnedSize = 0;
    const OSStatus status = (*driver)->GetPropertyData(
        driver, objectID, 0, &address, 0, NULL,
        sizeof(value), &returnedSize, &value);
    CHECK(status == noErr && returnedSize == sizeof(value),
          "UInt32 property object=%u selector=0x%x scope=0x%x status=%d size=%u",
          objectID, selector, scope, status, returnedSize);
    return value;
}

struct PropertyProbe {
    AudioObjectID objectID;
    AudioObjectPropertySelector selector;
    AudioObjectPropertyScope scope;
};

static void probe_property(AudioServerPlugInDriverRef driver,
                           const struct PropertyProbe *probe)
{
    const AudioObjectPropertyAddress address = {
        probe->selector, probe->scope, kAudioObjectPropertyElementMain
    };
    CHECK((*driver)->HasProperty(driver, probe->objectID, 0, &address),
          "probe property missing object=%u selector=0x%x scope=0x%x",
          probe->objectID, probe->selector, probe->scope);

    Boolean isSettable = false;
    OSStatus status = (*driver)->IsPropertySettable(
        driver, probe->objectID, 0, &address, &isSettable);
    CHECK(status == noErr,
          "IsPropertySettable object=%u selector=0x%x scope=0x%x status=%d",
          probe->objectID, probe->selector, probe->scope, status);

    UInt32 advertisedSize = UINT32_MAX;
    status = (*driver)->GetPropertyDataSize(
        driver, probe->objectID, 0, &address, 0, NULL, &advertisedSize);
    CHECK(status == noErr,
          "GetPropertyDataSize object=%u selector=0x%x scope=0x%x status=%d",
          probe->objectID, probe->selector, probe->scope, status);
    if (status != noErr) { return; }

    enum { guardSize = 32 };
    const size_t allocationSize = guardSize + (size_t)advertisedSize + guardSize;
    uint8_t *allocation = malloc(allocationSize);
    CHECK(allocation != NULL, "property probe allocation failed");
    if (allocation == NULL) { return; }
    memset(allocation, 0xA7, allocationSize);
    void *data = allocation + guardSize;
    UInt32 returnedSize = UINT32_MAX;
    status = (*driver)->GetPropertyData(
        driver, probe->objectID, 0, &address, 0, NULL,
        advertisedSize, &returnedSize, data);
    CHECK(status == noErr,
          "GetPropertyData object=%u selector=0x%x scope=0x%x status=%d",
          probe->objectID, probe->selector, probe->scope, status);
    CHECK(returnedSize == advertisedSize,
          "property size mismatch object=%u selector=0x%x scope=0x%x advertised=%u returned=%u",
          probe->objectID, probe->selector, probe->scope,
          advertisedSize, returnedSize);

    for (size_t index = 0; index < guardSize; ++index)
    {
        CHECK(allocation[index] == 0xA7,
              "property underflow object=%u selector=0x%x at guard byte=%zu",
              probe->objectID, probe->selector, index);
        CHECK(allocation[guardSize + advertisedSize + index] == 0xA7,
              "property overflow object=%u selector=0x%x at guard byte=%zu",
              probe->objectID, probe->selector, index);
    }
    free(allocation);
}

static void check_all_published_properties(AudioServerPlugInDriverRef driver)
{
    const AudioObjectPropertySelector plugInSelectors[] = {
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyOwnedObjects,
        kAudioPlugInPropertyBoxList,
        kAudioPlugInPropertyDeviceList,
        kAudioPlugInPropertyResourceBundle
    };
    for (size_t index = 0; index < sizeof(plugInSelectors) / sizeof(plugInSelectors[0]); ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_PlugIn, plugInSelectors[index], kAudioObjectPropertyScopeGlobal
        };
        probe_property(driver, &probe);
    }

    const AudioObjectPropertySelector deviceGlobalSelectors[] = {
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyName,
        kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyDeviceUID,
        kAudioDevicePropertyModelUID,
        kAudioDevicePropertyTransportType,
        kAudioDevicePropertyRelatedDevices,
        kAudioDevicePropertyClockDomain,
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunning,
        kAudioObjectPropertyControlList,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyZeroTimeStampPeriod,
        kAudioDevicePropertyStreams
    };
    for (size_t index = 0;
         index < sizeof(deviceGlobalSelectors) / sizeof(deviceGlobalSelectors[0]);
         ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_Device, deviceGlobalSelectors[index], kAudioObjectPropertyScopeGlobal
        };
        probe_property(driver, &probe);
    }

    const AudioObjectPropertySelector deviceInputSelectors[] = {
        kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioDevicePropertyLatency,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyControlList,
        kAudioDevicePropertySafetyOffset,
        kAudioDevicePropertyPreferredChannelLayout
    };
    for (size_t index = 0;
         index < sizeof(deviceInputSelectors) / sizeof(deviceInputSelectors[0]);
         ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_Device, deviceInputSelectors[index], kAudioObjectPropertyScopeInput
        };
        probe_property(driver, &probe);
    }

    const AudioObjectPropertySelector deviceEmptyOutputSelectors[] = {
        kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyControlList
    };
    for (size_t index = 0;
         index < sizeof(deviceEmptyOutputSelectors) / sizeof(deviceEmptyOutputSelectors[0]);
         ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_Device, deviceEmptyOutputSelectors[index], kAudioObjectPropertyScopeOutput
        };
        probe_property(driver, &probe);
    }

    const AudioObjectPropertySelector streamSelectors[] = {
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyOwnedObjects,
        kAudioStreamPropertyIsActive,
        kAudioStreamPropertyDirection,
        kAudioStreamPropertyTerminalType,
        kAudioStreamPropertyStartingChannel,
        kAudioStreamPropertyLatency,
        kAudioStreamPropertyVirtualFormat,
        kAudioStreamPropertyPhysicalFormat,
        kAudioStreamPropertyAvailableVirtualFormats,
        kAudioStreamPropertyAvailablePhysicalFormats
    };
    for (size_t index = 0; index < sizeof(streamSelectors) / sizeof(streamSelectors[0]); ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_Stream_Input, streamSelectors[index], kAudioObjectPropertyScopeGlobal
        };
        probe_property(driver, &probe);
    }

    const AudioObjectPropertySelector controlCommonSelectors[] = {
        kAudioObjectPropertyBaseClass,
        kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner,
        kAudioObjectPropertyOwnedObjects,
        kAudioControlPropertyScope,
        kAudioControlPropertyElement
    };
    const AudioObjectID controls[] = {
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
        kObjectID_ClockSource
    };
    for (size_t objectIndex = 0; objectIndex < sizeof(controls) / sizeof(controls[0]); ++objectIndex)
    {
        for (size_t selectorIndex = 0;
             selectorIndex < sizeof(controlCommonSelectors) / sizeof(controlCommonSelectors[0]);
             ++selectorIndex)
        {
            const struct PropertyProbe probe = {
                controls[objectIndex],
                controlCommonSelectors[selectorIndex],
                kAudioObjectPropertyScopeGlobal
            };
            probe_property(driver, &probe);
        }
    }

    const AudioObjectPropertySelector volumeSelectors[] = {
        kAudioLevelControlPropertyScalarValue,
        kAudioLevelControlPropertyDecibelValue,
        kAudioLevelControlPropertyDecibelRange,
        kAudioLevelControlPropertyConvertScalarToDecibels,
        kAudioLevelControlPropertyConvertDecibelsToScalar
    };
    for (size_t index = 0; index < sizeof(volumeSelectors) / sizeof(volumeSelectors[0]); ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_Volume_Input_Master,
            volumeSelectors[index],
            kAudioObjectPropertyScopeGlobal
        };
        probe_property(driver, &probe);
    }

    const struct PropertyProbe muteProbe = {
        kObjectID_Mute_Input_Master,
        kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal
    };
    probe_property(driver, &muteProbe);

    const AudioObjectPropertySelector clockSelectors[] = {
        kAudioSelectorControlPropertyCurrentItem,
        kAudioSelectorControlPropertyAvailableItems
    };
    for (size_t index = 0; index < sizeof(clockSelectors) / sizeof(clockSelectors[0]); ++index)
    {
        const struct PropertyProbe probe = {
            kObjectID_ClockSource,
            clockSelectors[index],
            kAudioObjectPropertyScopeGlobal
        };
        probe_property(driver, &probe);
    }
}

static void check_exact_list(const char *name,
                             const AudioObjectID *actual,
                             UInt32 actualCount,
                             const AudioObjectID *expected,
                             UInt32 expectedCount)
{
    CHECK(actualCount == expectedCount, "%s count=%u expected=%u",
          name, actualCount, expectedCount);
    const UInt32 comparable = actualCount < expectedCount ? actualCount : expectedCount;
    for (UInt32 index = 0; index < comparable; ++index)
    {
        CHECK(actual[index] == expected[index], "%s[%u]=%u expected=%u",
              name, index, actual[index], expected[index]);
    }
}

static AudioObjectID translate_uid(AudioServerPlugInDriverRef driver,
                                   AudioObjectPropertySelector selector,
                                   CFStringRef uid,
                                   UInt32 qualifierSize,
                                   OSStatus *statusOut)
{
    const AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID translated = UINT32_MAX;
    UInt32 returnedSize = 0;
    const OSStatus status = (*driver)->GetPropertyData(
        driver, kObjectID_PlugIn, 0, &address,
        qualifierSize, &uid, sizeof(translated), &returnedSize, &translated);
    if (statusOut != NULL) { *statusOut = status; }
    if (status == noErr)
    {
        CHECK(returnedSize == sizeof(translated),
              "UID translation selector=0x%x returned size=%u",
              selector, returnedSize);
    }
    return translated;
}

static void check_uid_translation(AudioServerPlugInDriverRef driver)
{
    OSStatus status = noErr;
    CFStringRef boxUID = CFSTR("SiriRemoteMic_UID");
    AudioObjectID translated = translate_uid(
        driver, kAudioPlugInPropertyTranslateUIDToBox,
        boxUID, sizeof(boxUID), &status);
    CHECK(status == noErr && translated == kAudioObjectUnknown,
          "box UID translation status=%d object=%u", status, translated);

    CFStringRef deviceUID = CFSTR("SiriRemoteMic_UID");
    translated = translate_uid(
        driver, kAudioPlugInPropertyTranslateUIDToDevice,
        deviceUID, sizeof(deviceUID), &status);
    CHECK(status == noErr && translated == kObjectID_Device,
          "device UID translation status=%d object=%u", status, translated);

    CFStringRef unknownUID = CFSTR("not.this.driver");
    translated = translate_uid(
        driver, kAudioPlugInPropertyTranslateUIDToDevice,
        unknownUID, sizeof(unknownUID), &status);
    CHECK(status == noErr && translated == kAudioObjectUnknown,
          "unknown UID translation status=%d object=%u", status, translated);

    (void)translate_uid(
        driver, kAudioPlugInPropertyTranslateUIDToDevice,
        deviceUID, (UInt32)(sizeof(deviceUID) - 1), &status);
    CHECK(status == kAudioHardwareBadPropertySizeError,
          "bad UID qualifier size status=%d expected=%d",
          status, kAudioHardwareBadPropertySizeError);
}

static void check_object_graph(AudioServerPlugInDriverRef driver)
{
    AudioObjectID values[8] = {0};

    const AudioObjectID expectedPlugInOwned[] = { kObjectID_Device };
    UInt32 count = object_list(driver, kObjectID_PlugIn, kAudioObjectPropertyOwnedObjects,
                               kAudioObjectPropertyScopeGlobal, values, 8);
    check_exact_list("plugin owned objects", values, count, expectedPlugInOwned, 1);

    const AudioObjectID expectedDevices[] = { kObjectID_Device };
    count = object_list(driver, kObjectID_PlugIn, kAudioPlugInPropertyDeviceList,
                        kAudioObjectPropertyScopeGlobal, values, 8);
    check_exact_list("plugin device list", values, count, expectedDevices, 1);

    count = object_list(driver, kObjectID_PlugIn, kAudioPlugInPropertyBoxList,
                        kAudioObjectPropertyScopeGlobal, values, 8);
    check_exact_list("plugin box list", values, count, NULL, 0);

    const AudioObjectID expectedDeviceOwned[] = {
        kObjectID_Stream_Input,
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
        kObjectID_ClockSource
    };
    count = object_list(driver, kObjectID_Device, kAudioObjectPropertyOwnedObjects,
                        kAudioObjectPropertyScopeGlobal, values, 8);
    check_exact_list("device owned objects", values, count, expectedDeviceOwned, 4);

    const AudioObjectID expectedInputStreams[] = { kObjectID_Stream_Input };
    count = object_list(driver, kObjectID_Device, kAudioDevicePropertyStreams,
                        kAudioObjectPropertyScopeInput, values, 8);
    check_exact_list("input streams", values, count, expectedInputStreams, 1);

    count = object_list(driver, kObjectID_Device, kAudioDevicePropertyStreams,
                        kAudioObjectPropertyScopeOutput, values, 8);
    check_exact_list("output streams", values, count, NULL, 0);

    CHECK(object_owner(driver, kObjectID_Device) == kObjectID_PlugIn,
          "device owner is not plug-in");
    for (UInt32 index = 0; index < 4; ++index)
    {
        CHECK(object_owner(driver, expectedDeviceOwned[index]) == kObjectID_Device,
              "object %u owner is not device", expectedDeviceOwned[index]);
    }
}

static void check_published_surface(AudioServerPlugInDriverRef driver)
{
    const AudioObjectID unpublished[] = {
        kObjectID_Box,
        kObjectID_Device2,
        kObjectID_Stream_Output,
        kObjectID_Volume_Output_Master,
        kObjectID_Mute_Output_Master,
        kObjectID_Pitch_Adjust
    };
    for (size_t index = 0; index < sizeof(unpublished) / sizeof(unpublished[0]); ++index)
    {
        CHECK(!has_property(driver, unpublished[index], kAudioObjectPropertyBaseClass,
                            kAudioObjectPropertyScopeGlobal),
              "unpublished object %u is reachable", unpublished[index]);
    }

    CHECK(has_property(driver, kObjectID_Device,
                       kAudioDevicePropertyDeviceCanBeDefaultDevice,
                       kAudioObjectPropertyScopeInput),
          "input device does not publish default-input capability");
    CHECK(uint32_property(driver, kObjectID_Device,
                          kAudioDevicePropertyDeviceCanBeDefaultDevice,
                          kAudioObjectPropertyScopeInput) == 1,
          "device must be eligible as the DEFAULT INPUT — GUI apps (e.g. Typeless) list only "
          "default-eligible mics, so a 0 here makes the device invisible in their picker even "
          "though it opens fine by name. A real built-in mic reports 1 too.");
    CHECK(!has_property(driver, kObjectID_Device,
                        kAudioDevicePropertyDeviceCanBeDefaultDevice,
                        kAudioObjectPropertyScopeOutput),
          "input-only device advertises default-output capability");
    CHECK(!has_property(driver, kObjectID_Device,
                        kAudioDevicePropertyPreferredChannelsForStereo,
                        kAudioObjectPropertyScopeInput),
          "mono device advertises a preferred stereo channel pair");
    CHECK(!has_property(driver, kObjectID_Device,
                        kAudioDevicePropertyIcon,
                        kAudioObjectPropertyScopeGlobal),
          "device advertises a missing icon resource");

    const OSStatus status = (*driver)->StartIO(driver, kObjectID_Device2, 77);
    CHECK(status == kAudioHardwareBadObjectError,
          "unpublished mirror device StartIO status=%d expected=%d",
          status, kAudioHardwareBadObjectError);
}

static void check_reconciliation_stability(AudioServerPlugInDriverRef driver)
{
    const AudioObjectID expectedDevice[] = { kObjectID_Device };
    AudioObjectID values[4] = {0};
    CFStringRef deviceUID = CFSTR("SiriRemoteMic_UID");

    for (unsigned iteration = 0; iteration < 20000; ++iteration)
    {
        UInt32 count = object_list(
            driver, kObjectID_PlugIn, kAudioObjectPropertyOwnedObjects,
            kAudioObjectPropertyScopeGlobal, values, 4);
        if (count != 1 || values[0] != expectedDevice[0])
        {
            CHECK(false, "owned-object graph changed at iteration=%u", iteration);
            break;
        }

        count = object_list(
            driver, kObjectID_PlugIn, kAudioPlugInPropertyDeviceList,
            kAudioObjectPropertyScopeGlobal, values, 4);
        if (count != 1 || values[0] != expectedDevice[0])
        {
            CHECK(false, "device list changed at iteration=%u", iteration);
            break;
        }

        count = object_list(
            driver, kObjectID_PlugIn, kAudioPlugInPropertyBoxList,
            kAudioObjectPropertyScopeGlobal, values, 4);
        if (count != 0)
        {
            CHECK(false, "box list changed at iteration=%u", iteration);
            break;
        }

        OSStatus status = noErr;
        const AudioObjectID translated = translate_uid(
            driver, kAudioPlugInPropertyTranslateUIDToDevice,
            deviceUID, sizeof(deviceUID), &status);
        if (status != noErr || translated != kObjectID_Device)
        {
            CHECK(false, "UID translation changed at iteration=%u status=%d object=%u",
                  iteration, status, translated);
            break;
        }
    }
}

static void check_io_contract(AudioServerPlugInDriverRef driver)
{
    Boolean willDo = false;
    Boolean inPlace = false;
    OSStatus status = (*driver)->WillDoIOOperation(
        driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationReadInput,
        &willDo, &inPlace);
    CHECK(status == noErr && willDo && inPlace,
          "ReadInput support status=%d will=%u inPlace=%u", status, willDo, inPlace);

    willDo = true;
    inPlace = true;
    status = (*driver)->WillDoIOOperation(
        driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix,
        &willDo, &inPlace);
    CHECK(status == noErr && !willDo,
          "input-only device claims WriteMix status=%d will=%u", status, willDo);

    const UInt64 beforeStart = mach_absolute_time();
    status = (*driver)->StartIO(driver, kObjectID_Device, 1);
    CHECK(status == noErr, "StartIO status=%d", status);
    if (status != noErr) { return; }

    Float64 sampleTime = -1.0;
    UInt64 hostTime = 0;
    UInt64 seed = 0;
    status = (*driver)->GetZeroTimeStamp(
        driver, kObjectID_Device, 1, &sampleTime, &hostTime, &seed);
    const UInt64 after = mach_absolute_time();
    CHECK(status == noErr, "GetZeroTimeStamp status=%d", status);
    CHECK(hostTime >= beforeStart && hostTime <= after,
          "initial host time %llu is outside [%llu, %llu]",
          (unsigned long long)hostTime, (unsigned long long)beforeStart,
          (unsigned long long)after);
    CHECK(sampleTime == 0.0 && seed == 1,
          "initial timestamp sample=%.0f seed=%llu",
          sampleTime, (unsigned long long)seed);

    usleep(380000);
    Float64 laterSampleTime = -1.0;
    UInt64 laterHostTime = 0;
    UInt64 laterSeed = 0;
    status = (*driver)->GetZeroTimeStamp(
        driver, kObjectID_Device, 1, &laterSampleTime, &laterHostTime, &laterSeed);
    CHECK(status == noErr, "second GetZeroTimeStamp status=%d", status);
    CHECK(laterSampleTime == 16384.0,
          "second sample time %.0f expected 16384", laterSampleTime);
    CHECK(laterHostTime > hostTime && laterSeed == seed,
          "second timestamp did not advance on the same timeline");

    float samples[512];
    for (size_t index = 0; index < 512; ++index) { samples[index] = 1.0f; }
    AudioServerPlugInIOCycleInfo cycle = {0};
    status = (*driver)->DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Input, 1,
        kAudioServerPlugInIOOperationReadInput, 512, &cycle, samples, NULL);
    CHECK(status == noErr, "DoIOOperation ReadInput status=%d", status);
    for (size_t index = 0; index < 512; ++index)
    {
        if (samples[index] != 0.0f)
        {
            CHECK(false, "ReadInput without producer was not silent at sample %zu", index);
            break;
        }
    }

    status = (*driver)->StopIO(driver, kObjectID_Device, 1);
    CHECK(status == noErr, "StopIO status=%d", status);
}

int main(int argumentCount, char **arguments)
{
    if (argumentCount != 2)
    {
        fprintf(stderr, "usage: %s /path/to/SiriRemoteMic\n", arguments[0]);
        return 2;
    }

    // Private IPC namespace (read by the driver's Initialize): keeps this offline test from
    // waking the machine's real capture supervisor via the consumers notification, and from
    // attaching whatever live producers left in the production shm rings. This test creates
    // no rings, so with the suffix the driver's ReadInput must serve silence.
    setenv("SRM_IPC_SUFFIX", ".contract", 1);

    void *bundle = dlopen(arguments[1], RTLD_NOW | RTLD_LOCAL);
    if (bundle == NULL)
    {
        fprintf(stderr, "contract test: dlopen: %s\n", dlerror());
        return 2;
    }

    typedef void *(*FactoryFunction)(CFAllocatorRef, CFUUIDRef);
    FactoryFunction factory = (FactoryFunction)dlsym(bundle, "BlackHole_Create");
    if (factory == NULL)
    {
        fprintf(stderr, "contract test: dlsym: %s\n", dlerror());
        dlclose(bundle);
        return 2;
    }

    AudioServerPlugInDriverRef driver =
        (AudioServerPlugInDriverRef)factory(NULL, kAudioServerPlugInTypeUUID);
    CHECK(driver != NULL, "factory rejected AudioServerPlugIn type UUID");
    if (driver != NULL)
    {
        const OSStatus status = (*driver)->Initialize(driver, &kFakeHost);
        CHECK(status == noErr, "Initialize status=%d", status);
        if (status == noErr)
        {
            check_object_graph(driver);
            check_published_surface(driver);
            check_uid_translation(driver);
            check_all_published_properties(driver);
            check_reconciliation_stability(driver);
            check_io_contract(driver);
        }
    }
    CHECK(gUnexpectedNotifications == 0,
          "driver emitted %u unexpected host notification(s)", gUnexpectedNotifications);

    dlclose(bundle);
    if (gFailures != 0)
    {
        fprintf(stderr, "contract test: %u failure(s)\n", gFailures);
        return 1;
    }
    puts("contract test: PASS");
    return 0;
}
