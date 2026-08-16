//
//  BuiltinMicRingWriter.h
//  HyperVibe
//
//  Producer side of the BUILT-IN-mic fallback ring ("/SiriRemoteMicBuiltin") that the
//  SiriRemoteMic HAL plug-in serves whenever the remote's voice ring is stale. Small C
//  bridge in the same mold as mic/router/SiriRemoteMicRingWriter.c: C owns the C11
//  atomics of the shared-memory ABI so Swift never has to guess their layout or
//  memory-ordering semantics.
//
#ifndef BUILTIN_MIC_RING_WRITER_H
#define BUILTIN_MIC_RING_WRITER_H

#include <stddef.h>
#include <stdint.h>

int srm_builtin_ring_open(void);
void srm_builtin_ring_close(void);
void srm_builtin_ring_set_active(int active);
// 48 kHz mono Float32 frames, already in ring units — the Swift side converts first.
int srm_builtin_ring_write(const float *samples, size_t frame_count);
uint64_t srm_builtin_ring_write_index(void);
const char *srm_builtin_ring_last_error(void);

// Lock-free bridge for the compact Voice waveform. The AUHAL render callback publishes
// the latest mono mean-square power; the feeder queue polls it at display cadence. Keeping
// this value in C means Swift never races on a Float shared with the real-time audio thread.
void srm_builtin_meter_store_power(float mean_square_power);
float srm_builtin_meter_load_power(void);

// Acoustic features derived from a recent 48 kHz mono PCM window. Analysis happens only
// when the feeder's 30 Hz display timer asks for a snapshot — never on the real-time AUHAL
// callback. pitch_hz is zero when the window is unvoiced or confidence is too low.
typedef struct SRMMeterFeatures
{
    float meanSquarePower;
    float pitchHz;
    float pitchConfidence;
    float brightness;
} SRMMeterFeatures;

// Read-only snapshot of the built-in fallback ring. write_index/producer_active let Swift
// reject a stale window after capture starts, using the same monotonic publication contract.
int srm_builtin_meter_snapshot(SRMMeterFeatures *features,
                               uint64_t *write_index,
                               uint32_t *producer_active);

// Read-only snapshot of the decoded remote-voice ring. Returns 0 when the ring is mapped
// and valid; callers decide freshness from write_index movement, exactly as the HAL plug-in
// does. This never creates or mutates the remote producer's shared-memory object.
int srm_remote_meter_snapshot(SRMMeterFeatures *features,
                              uint64_t *write_index,
                              uint32_t *producer_active);

#endif /* BUILTIN_MIC_RING_WRITER_H */
