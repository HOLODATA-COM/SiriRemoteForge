//
//  MonitorAudioRing.h
//
//  Process-local, lock-free single-producer/single-consumer float ring for the live
//  "ear monitor". The producer is the decode loop (any thread); the consumer is the
//  AVAudioSourceNode render callback, which runs on a CoreAudio real-time thread and must
//  never lock, allocate or block. C owns the C11 atomics so the Swift side stays trivial —
//  the same split used by SiriRemoteMicRingWriter.c for the HAL ring.
//
//  Jitter-buffer policy (all in mon_ring_read):
//    * Prime gate: after a reset, stay silent until `primeFrames` are buffered, so the
//      steady 48 kHz output clock never immediately overruns the bursty ~50 fps producer.
//    * Underrun: if the buffer runs dry mid-hold, emit silence for the missing samples and
//      re-arm the gate at the SMALLER `reprimeFrames` — a transient dip costs ~one frame of
//      silence, not a full prime. (A genuine end-of-hold just stays silent until refilled.)
//    * Overflow: if the producer outruns the consumer past `maxLatencyFrames` (clock drift
//      or the reader falling behind), the consumer drops the oldest samples to bound latency.
//
#ifndef SIRI_REMOTE_MIC_MONITOR_AUDIO_RING_H
#define SIRI_REMOTE_MIC_MONITOR_AUDIO_RING_H

#include <stddef.h>
#include <stdint.h>

// Set thresholds (in frames @ 48 kHz) and clear the ring. Call before starting the engine.
void     mon_ring_configure(uint32_t primeFrames, uint32_t reprimeFrames, uint32_t maxLatencyFrames);
void     mon_ring_reset(void);

// Producer: push decoded PCM. Applies `gain` with hard-clip protection. Never blocks.
void     mon_ring_write_int16(const int16_t *samples, size_t frameCount, float gain);

// Consumer (render thread): fill `out` with `frameCount` mono floats. Handles prime,
// underrun (silence) and overflow (drop-oldest) internally. Never blocks or allocates.
void     mon_ring_read(float *out, size_t frameCount);

// Diagnostics (safe to read from any thread).
uint64_t mon_ring_underruns(void);        // number of render callbacks that hit an underrun
uint64_t mon_ring_silence_frames(void);   // total frames emitted as silence (prime + underrun)
uint64_t mon_ring_write_index(void);      // total frames written by the producer
uint64_t mon_ring_read_index(void);       // total frames consumed by the render thread

#endif /* SIRI_REMOTE_MIC_MONITOR_AUDIO_RING_H */
