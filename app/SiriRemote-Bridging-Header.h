//
//  SiriRemote-Bridging-Header.h
//  HyperVibe
//
//  Bridging header to expose MultitouchSupport private framework to Swift
//

#ifndef SiriRemote_Bridging_Header_h
#define SiriRemote_Bridging_Header_h

#import "MultitouchSupport.h"

// Virtual-mic fallback (Phase 2b): Darwin notifications for the plug-in's demand signal,
// and the C writer that owns the shared-memory ring's atomics.
#import <notify.h>
#import "BuiltinMicRingWriter.h"

#endif /* SiriRemote_Bridging_Header_h */
