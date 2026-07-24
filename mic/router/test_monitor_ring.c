//
//  test_monitor_ring.c
//
//  Offline validation of the ear-monitor jitter buffer's render logic (the part that cannot
//  be exercised without live audio). Simulates producer/consumer interleavings and asserts
//  the prime / underrun-reprime / overflow behaviour.
//
#include "MonitorAudioRing.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int gFailures = 0;

static void check(int cond, const char *what)
{
    if (!cond) { fprintf(stderr, "  FAIL: %s\n", what); ++gFailures; }
}

static int nonSilent(const float *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) { if (b[i] != 0.0f) { return 1; } }
    return 0;
}

// Fill a buffer of int16 ones so decoded audio is clearly non-zero.
static void ones(int16_t *b, size_t n) { for (size_t i = 0; i < n; ++i) { b[i] = 4000; } }

int main(void)
{
    const size_t QUANTUM = 512;           // typical CoreAudio render size
    float out[512];
    int16_t frame[960];                   // one 20 ms Opus frame @ 48 kHz
    ones(frame, 960);

    // ---- Test 1: prime gate holds silence until primeFrames buffered ----
    mon_ring_configure(/*prime*/4800, /*reprime*/960, /*maxLatency*/48000);
    mon_ring_write_int16(frame, 960, 1.0f);           // 960 < 4800 → still silent
    mon_ring_read(out, QUANTUM);
    check(!nonSilent(out, QUANTUM), "prime: silent while under target");
    check(mon_ring_underruns() == 0, "prime: under-target silence is not an underrun");
    for (int i = 0; i < 5; ++i) { mon_ring_write_int16(frame, 960, 1.0f); } // now 5760 >= 4800
    mon_ring_read(out, QUANTUM);
    check(nonSilent(out, QUANTUM), "prime: audio flows once target reached");

    // ---- Test 2: steady 50 fps feed vs 48 kHz pull → no underruns ----
    mon_ring_configure(4800, 960, 48000);
    for (int i = 0; i < 5; ++i) { mon_ring_write_int16(frame, 960, 1.0f); }   // prime
    // Emulate ~10 s: every 20 ms one 960 frame arrives; the DAC pulls 960 frames per 20 ms
    // as ~2 render quanta. Feed then drain the exact same rate.
    for (int tick = 0; tick < 500; ++tick)
    {
        mon_ring_write_int16(frame, 960, 1.0f);
        mon_ring_read(out, 480);
        mon_ring_read(out, 480);
    }
    check(mon_ring_underruns() == 0, "steady: no underruns at matched rate");
    check(nonSilent(out, 480), "steady: still producing audio at the end");

    // ---- Test 3: underrun mid-hold re-primes cheaply, then recovers ----
    mon_ring_configure(4800, 960, 48000);
    for (int i = 0; i < 5; ++i) { mon_ring_write_int16(frame, 960, 1.0f); }
    // Drain far more than produced to force a dry buffer.
    for (int i = 0; i < 20; ++i) { mon_ring_read(out, QUANTUM); }
    check(mon_ring_underruns() >= 1, "underrun: detected when drained dry");
    uint64_t underrunsAfterDip = mon_ring_underruns();
    // A single 20 ms frame (960 >= reprime 960) should re-open the gate → audio resumes.
    mon_ring_write_int16(frame, 960, 1.0f);
    mon_ring_read(out, QUANTUM);
    check(nonSilent(out, QUANTUM), "reprime: one frame is enough to resume after a dip");
    check(mon_ring_underruns() == underrunsAfterDip, "reprime: resume did not add an underrun");

    // ---- Test 4: overflow drop bounds latency ----
    mon_ring_configure(4800, 960, 48000);
    for (int i = 0; i < 200; ++i) { mon_ring_write_int16(frame, 960, 1.0f); } // 192000 frames, >> 1 s
    mon_ring_read(out, QUANTUM);   // first read drops oldest down to maxLatency
    uint64_t backlog = mon_ring_write_index() - mon_ring_read_index();
    check(backlog <= 48000, "overflow: backlog bounded to maxLatency after a read");
    check(nonSilent(out, QUANTUM), "overflow: still plays (kept the newest audio)");

    if (gFailures == 0) { printf("monitor ring test: PASS\n"); return 0; }
    fprintf(stderr, "monitor ring test: %d FAILURE(S)\n", gFailures);
    return 1;
}
