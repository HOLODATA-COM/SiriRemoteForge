#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

static id attribute(AXUIElementRef element, CFStringRef name) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
bool vi_trusted(bool prompt) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
char *vi_capture(bool selection) {
    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(application, 0.15);
        CFTypeRef focus = NULL;
        AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute, &focus);
        CFRelease(application);
        AXUIElementRef element = (AXUIElementRef)focus;
        if (element) AXUIElementSetMessagingTimeout(element, 0.15);
        NSString *role = attribute(element, kAXRoleAttribute);
        NSString *subrole = attribute(element, kAXSubroleAttribute);
        BOOL secure = IsSecureEventInputEnabled() || [role isEqualToString:@"AXSecureTextField"] || [subrole isEqualToString:@"AXSecureTextField"];
        NSString *selected = (selection && !secure) ? attribute(element, kAXSelectedTextAttribute) : nil;
        if (![selected isKindOfClass:NSString.class] || selected.length > 20000) selected = nil;
        Boolean settable = false;
        if (element) AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute, &settable);
        NSDictionary *value = @{@"pid": @(app.processIdentifier), @"handle": @((uintptr_t)focus),
            @"application": app.bundleIdentifier ?: app.localizedName ?: @"unknown",
            @"secure": @(secure), @"selection": selected ?: @"", @"replaceable": @(settable)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        return strdup([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
}
void vi_free(char *value) { free(value); }
void vi_release(uintptr_t handle) { if (handle) CFRelease((CFTypeRef)handle); }
bool vi_valid(int pid, uintptr_t handle) {
    @autoreleasepool {
        if (!handle || IsSecureEventInputEnabled() || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != pid) return false;
        AXUIElementRef application = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(application, 0.1);
        CFTypeRef focus = NULL;
        AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute, &focus);
        CFRelease(application);
        if (!focus) return false;
        NSString *role = attribute((AXUIElementRef)focus, kAXRoleAttribute);
        NSString *subrole = attribute((AXUIElementRef)focus, kAXSubroleAttribute);
        bool matches = CFEqual(focus, (CFTypeRef)handle)
            && ![role isEqualToString:@"AXSecureTextField"] && ![subrole isEqualToString:@"AXSecureTextField"];
        CFRelease(focus); return matches;
    }
}
bool vi_selection_matches(uintptr_t handle, const char *original) {
    @autoreleasepool {
        NSString *selected = attribute((AXUIElementRef)handle, kAXSelectedTextAttribute);
        return [selected isKindOfClass:NSString.class] && [selected isEqualToString:[NSString stringWithUTF8String:original]];
    }
}
bool vi_replace(uintptr_t handle, const char *original, const char *replacement) {
    @autoreleasepool {
        if (!vi_selection_matches(handle, original)) return false;
        return AXUIElementSetAttributeValue((AXUIElementRef)handle, kAXSelectedTextAttribute,
            (__bridge CFStringRef)[NSString stringWithUTF8String:replacement]) == kAXErrorSuccess;
    }
}
