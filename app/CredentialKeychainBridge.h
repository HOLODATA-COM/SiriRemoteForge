//
//  CredentialKeychainBridge.h
//  HyperVibe
//
//  Narrow compatibility bridge for login-keychain ACL APIs. HyperVibe's stable local signing
//  identity intentionally has no Apple provisioning profile, so the entitlement-gated data-
//  protection keychain is unavailable to development builds.
//

#ifndef CREDENTIAL_KEYCHAIN_BRIDGE_H
#define CREDENTIAL_KEYCHAIN_BRIDGE_H

#include <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

SecKeychainRef _Nullable hv_open_keychain(const char *_Nonnull path,
                                          OSStatus *_Nonnull status)
    CF_RETURNS_RETAINED;

// Pass NULL to trust the calling executable (used inside the immutable broker), or an absolute
// executable path when the foreground App bootstraps the broker's first credential item.
SecAccessRef _Nullable hv_create_credential_access(const char *_Nullable executable_path,
                                                    OSStatus *_Nonnull status)
    CF_RETURNS_RETAINED;

#ifdef __cplusplus
}
#endif

#endif /* CREDENTIAL_KEYCHAIN_BRIDGE_H */
