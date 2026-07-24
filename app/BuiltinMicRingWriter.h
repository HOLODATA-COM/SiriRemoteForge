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

#endif /* BUILTIN_MIC_RING_WRITER_H */
