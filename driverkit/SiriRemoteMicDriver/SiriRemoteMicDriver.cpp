#include <os/log.h>

#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/OSArray.h>
#include <HIDDriverKit/IOHIDInterface.h>

#include "SiriRemoteMicDriver.h"

namespace {
constexpr uint32_t kMaximumCapturedReportLength = 209;
constexpr uint32_t kAudioFeatureReportID = 0xff;
constexpr uint8_t kAudioActivationByte = 0xaf;
constexpr char kHexDigits[] = "0123456789abcdef";

kern_return_t
sendAudioActivationReport(IOService *provider)
{
    IOHIDInterface *interface = OSDynamicCast(IOHIDInterface, provider);
    if (interface == nullptr) {
        return kIOReturnBadArgument;
    }

    IOBufferMemoryDescriptor *report = nullptr;
    kern_return_t result = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionOut,
        sizeof(kAudioActivationByte),
        0,
        &report);
    if (result != kIOReturnSuccess || report == nullptr) {
        return result == kIOReturnSuccess ? kIOReturnNoMemory : result;
    }

    IOAddressSegment range = {};
    result = report->GetAddressRange(&range);
    if (result == kIOReturnSuccess) {
        if (range.address == 0 || range.length < sizeof(kAudioActivationByte)) {
            result = kIOReturnBadArgument;
        } else {
            auto *bytes = reinterpret_cast<uint8_t *>(range.address);
            bytes[0] = kAudioActivationByte;
        }
    }
    if (result == kIOReturnSuccess) {
        result = report->SetLength(sizeof(kAudioActivationByte));
    }
    if (result == kIOReturnSuccess) {
        result = interface->SetReport(
            report,
            kIOHIDReportTypeFeature,
            kAudioFeatureReportID,
            0);
    }

    OSSafeReleaseNULL(report);
    return result;
}
}

kern_return_t
IMPL(SiriRemoteMicDriver, Start)
{
    kern_return_t result = Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) {
        Stop(provider, SUPERDISPATCH);
        return result;
    }

    OSArray *elements = getElements();
    const uint32_t elementCount = elements == nullptr ? 0 : elements->getCount();

    const kern_return_t activationResult = sendAudioActivationReport(provider);
    os_log(OS_LOG_DEFAULT,
           "SiriRemoteMicDriver Feature 0xff [af] activation result=0x%x",
           activationResult);

    result = RegisterService();
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "SiriRemoteMicDriver failed to register: 0x%x",
               result);
        Stop(provider, SUPERDISPATCH);
        return result;
    }

    os_log(OS_LOG_DEFAULT,
           "SiriRemoteMicDriver started on Siri Remote audio interface with %u HID elements; activation result=0x%x",
           elementCount,
           activationResult);
    return kIOReturnSuccess;
}

void
SiriRemoteMicDriver::handleReport(uint64_t timestamp,
                                  uint8_t *report,
                                  uint32_t reportLength,
                                  IOHIDReportType type,
                                  uint32_t reportID)
{
    const uint32_t capturedLength =
        report != nullptr && reportLength < kMaximumCapturedReportLength
            ? reportLength
            : (report == nullptr ? 0 : kMaximumCapturedReportLength);
    char hexadecimalReport[(kMaximumCapturedReportLength * 2) + 1];

    for (uint32_t index = 0; index < capturedLength; ++index) {
        const uint8_t byte = report[index];
        hexadecimalReport[index * 2] = kHexDigits[byte >> 4];
        hexadecimalReport[(index * 2) + 1] = kHexDigits[byte & 0x0f];
    }
    hexadecimalReport[capturedLength * 2] = '\0';

    os_log(OS_LOG_DEFAULT,
           "SiriRemoteMicDriver report timestamp=%llu id=0x%x type=%u length=%u bytes=%{public}s",
           timestamp,
           reportID,
           static_cast<uint32_t>(type),
           reportLength,
           hexadecimalReport);
}
