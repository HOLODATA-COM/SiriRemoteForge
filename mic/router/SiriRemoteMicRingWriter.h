//
//  SiriRemoteMicRingWriter.h
//
//  Small C bridge used by the Swift router. C owns the C11 atomics in the shared-memory
//  ABI so Swift never has to guess their layout or memory-ordering semantics.
//
#ifndef SIRI_REMOTE_MIC_RING_WRITER_H
#define SIRI_REMOTE_MIC_RING_WRITER_H

#include <stddef.h>
#include <stdint.h>

int srm_ring_writer_open(void);
void srm_ring_writer_close(void);
void srm_ring_writer_set_active(int active);
int srm_ring_writer_write_int16(const int16_t *samples, size_t frame_count);
uint64_t srm_ring_writer_write_index(void);
const char *srm_ring_writer_last_error(void);

// The standalone CLI calls this after opening the ring. It makes SIGINT/SIGTERM/SIGHUP
// clear producerActive before exiting, preventing a dead producer from looking live.
void srm_ring_writer_install_signal_cleanup(void);

#endif /* SIRI_REMOTE_MIC_RING_WRITER_H */
