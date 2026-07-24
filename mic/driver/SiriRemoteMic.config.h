//
//  SiriRemoteMic.config.h
//
//  Overrides for the vendored, PRISTINE BlackHole.c (mic/driver/vendor/BlackHole.c,
//  © Existential Audio Inc., GPL-3.0). Every knob below is #ifndef-guarded in BlackHole.c,
//  so pulling this in first (clang -include) wins without touching upstream — which keeps
//  attribution clean and lets us re-sync BlackHole later.
//
//  One fixed-format input stream fed by the router's shared-memory ring. This software-only
//  device has a static object graph: no hardware Box and no inherited mirror device are published.
//
#ifndef SIRI_REMOTE_MIC_CONFIG_H
#define SIRI_REMOTE_MIC_CONFIG_H

#define kDriver_Name             "SiriRemoteMic"
#define kPlugIn_BundleID         "au.holodata.SiriRemoteMic"
#define kPlugIn_Icon             ""
#define kHas_Driver_Name_Format  0            // no " 2ch" suffix — use a fixed name
#define kDevice_Name             "Siri Remote Mic"
#define kDevice2_Name            "Siri Remote Mic (hidden)"
#define kManufacturer_Name       "Holodata.au"
#define kNumber_Of_Channels      1
#define kSampleRates             48000
#define kDevice_HasInput         true
#define kDevice_HasOutput        false
#define kDevice2_HasInput        false
#define kDevice2_HasOutput       false
#define kPlugIn_HasBox           false
#define kPlugIn_HasDevice2       false
#define kDevice_HasIcon          false
// MUST be true or apps that list only "can be the default input" devices (e.g. Typeless) filter the
// mic out of their picker entirely — even though it opens fine by name (that's why ffmpeg saw it but
// GUI apps didn't). A normal built-in mic and other listable virtual mics all report this true.
#define kCanBeDefaultDevice      true
// Left false: a microphone is not the SYSTEM default (that's for UI/alert output); the built-in mic
// reports false here too, and it is not what app input pickers key off.
#define kCanBeDefaultSystemDevice false

#endif /* SIRI_REMOTE_MIC_CONFIG_H */
