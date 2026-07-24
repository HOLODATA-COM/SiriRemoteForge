//
//  SiriRemoteMicShared.h
//
//  The IPC contract between the HAL plug-in (consumer, runs inside coreaudiod) and the
//  router/producer (our app, runs as the user). A single-producer / single-consumer
//  lock-free ring of Float32 samples in POSIX shared memory.
//
//  The producer creates the region (shm_open O_CREAT) and writes; the plug-in attaches
//  read-only and reads. No locks: the plug-in's ReadInput runs on a real-time thread, so
//  it only does atomic loads and memcpy — never allocates, never blocks.
//
//  M2a exists to answer one question: can a coreaudiod-hosted plug-in even see POSIX shared
//  memory a user process created? (coreaudiod is sandboxed.) Everything else is downstream.
//
#ifndef SIRI_REMOTE_MIC_SHARED_H
#define SIRI_REMOTE_MIC_SHARED_H

#include <stdint.h>
#include <stdatomic.h>

// POSIX shm name: must start with '/', <= 31 chars on macOS.
#define SRM_SHM_NAME     "/SiriRemoteMicAudio"
#define SRM_MAGIC        0x53524D31u   // 'SRM1'
#define SRM_VERSION      1u
#define SRM_CHANNELS     1u
#define SRM_RING_FRAMES  65536u        // ~1.36 s at 48 kHz, power of two

// Built-in-mic fallback ring: a SECOND region with the exact same SRMSharedMemory layout and
// producer discipline as SRM_SHM_NAME. A user-session producer (HyperVibe) shm_open(O_CREAT,0666)s
// it, fills magic/version/sampleRate(48000)/channels(1)/ringFrames(SRM_RING_FRAMES), writes 48 kHz
// mono Float32 built-in-mic samples into ring[writeIndex % SRM_RING_FRAMES], publishes each chunk
// by advancing writeIndex (release order, monotonic total frames), and keeps producerActive = 1
// while capturing (0 when it stops). The plug-in attaches READ-ONLY and serves this ring whenever
// the remote ring is stale; if the region does not exist the plug-in falls back to silence.
#define SRM_BUILTIN_SHM_NAME  "/SiriRemoteMicBuiltin"

// Consumer-side policy (NOT part of the producer contract). Lives here so the offline IO
// simulator asserts the exact numbers the plug-in ships with.
// The remote ring is FRESH while its writeIndex advanced within this many device frames;
// a stale remote (Siri button released — the router's writer stops) hands the device over
// to the built-in ring.
#define kSRM_RemoteStaleFrames  7200u   // ~150 ms @ 48 kHz
// Linear crossfade applied to every source switch (remote <-> built-in <-> silence).
#define kSRM_SourceFadeFrames    240u   // 5 ms @ 48 kHz

typedef struct {
    uint32_t          magic;           // SRM_MAGIC once the producer has initialised
    uint32_t          version;         // SRM_VERSION
    uint32_t          sampleRate;      // e.g. 48000
    uint32_t          channels;        // SRM_CHANNELS
    uint32_t          ringFrames;      // SRM_RING_FRAMES
    uint32_t          _pad;
    _Atomic uint32_t  producerActive;  // 1 while the router is feeding, else 0
    _Atomic uint64_t  writeIndex;      // total frames the producer has written (monotonic)
    float             ring[SRM_RING_FRAMES * SRM_CHANNELS];  // interleaved
} SRMSharedMemory;

#endif /* SIRI_REMOTE_MIC_SHARED_H */
