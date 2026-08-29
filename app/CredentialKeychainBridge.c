//
//  CredentialKeychainBridge.c
//  HyperVibe
//
//  Keep the unavoidable legacy API surface here so every other C/Swift source remains warning-
//  clean. These APIs are required specifically for an ACL-capable login-keychain item; modern
//  data-protection keychain calls require an Apple provisioning entitlement that the stable local
//  development identity cannot carry.
//

#include "CredentialKeychainBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

SecKeychainRef hv_open_keychain(const char *path, OSStatus *status)
{
    SecKeychainRef keychain = NULL;
    *status = SecKeychainOpen(path, &keychain);
    return keychain;
}

SecAccessRef hv_create_credential_access(const char *executable_path, OSStatus *status)
{
    SecTrustedApplicationRef trusted = NULL;
    *status = SecTrustedApplicationCreateFromPath(executable_path, &trusted);
    if (*status != errSecSuccess || trusted == NULL) {
        return NULL;
    }

    const void *values[] = { trusted };
    CFArrayRef trusted_apps = CFArrayCreate(kCFAllocatorDefault, values, 1,
                                            &kCFTypeArrayCallBacks);
    if (trusted_apps == NULL) {
        CFRelease(trusted);
        *status = errSecAllocate;
        return NULL;
    }

    SecAccessRef access = NULL;
    *status = SecAccessCreate(CFSTR("HyperVibe Cloud Credential"), trusted_apps, &access);
    CFRelease(trusted_apps);
    CFRelease(trusted);
    return access;
}

#pragma clang diagnostic pop
