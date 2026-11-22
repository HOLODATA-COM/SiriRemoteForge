#include "Devices.h"

enum { original, newWrapper, replacement, secondRemote, handleCount };
static int listedFirst = original;
static bool failStart;
static int starts[handleCount], stops[handleCount];
static bool running[handleCount];
static MTFrameCallbackRefconFunction callbacks[handleCount];
static void *contexts[handleCount];

static CFTypeRef device(int index) {
    const CFTypeRef handles[] = {CFSTR("original"), CFSTR("wrapper"), CFSTR("replacement"), CFSTR("second")};
    return handles[index];
}

static int indexOf(MTDeviceRef handle) {
    for (int i = 0; i < handleCount; ++i)
        if (handle == device(i)) return i;
    abort();
}

CFArrayRef MTDeviceCreateList(void) {
    const void *items[] = {device(listedFirst), device(secondRemote)};
    return CFArrayCreate(NULL, items, 2, &kCFTypeArrayCallBacks);
}

void replaceFirstService(void) { listedFirst = replacement; }
void refreshFirstWrapper(void) { listedFirst = newWrapper; }
void failNextStart(void) { failStart = true; }
int startCount(int handle) { return starts[handle]; }
int stopCount(int handle) { return stops[handle]; }

OSStatus MTDeviceGetDeviceID(MTDeviceRef handle, uint64_t *id) {
    *id = indexOf(handle) == secondRemote ? 24 : 42;
    return 0;
}
io_service_t MTDeviceGetService(MTDeviceRef handle) {
    int i = indexOf(handle);
    return i == newWrapper ? 100 : 100 + i;
}
boolean_t IOObjectIsEqualTo(io_object_t a, io_object_t b) { return a == b; }
OSStatus MTDeviceGetFamilyID(MTDeviceRef handle, int *family) { *family = 1; return 0; }
OSStatus MTDeviceGetSensorSurfaceDimensions(MTDeviceRef handle, int *width, int *height) {
    *width = *height = 2775;
    return 0;
}
bool MTDeviceIsBuiltIn(MTDeviceRef handle) { return false; }
bool MTDeviceIsRunning(MTDeviceRef handle) { return running[indexOf(handle)]; }
OSStatus MTDeviceStart(MTDeviceRef handle, int mode) {
    int i = indexOf(handle);
    ++starts[i];
    if (failStart) { failStart = false; return -1; }
    running[i] = true;
    return 0;
}
OSStatus MTDeviceStop(MTDeviceRef handle) {
    int i = indexOf(handle);
    ++stops[i];
    running[i] = false;
    return 0;
}
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef handle, MTFrameCallbackRefconFunction cb, void *context) {
    int i = indexOf(handle);
    callbacks[i] = cb;
    contexts[i] = context;
}
void MTUnregisterContactFrameCallback(MTDeviceRef handle, MTFrameCallbackRefconFunction cb) {
    // Retain the callback for the regression that replays a frame already in flight at detach.
}
void emitFrame(int handle, MTTouch *touches, size_t count, double timestamp) {
    callbacks[handle](device(handle), touches, count, timestamp, 0, contexts[handle]);
}
