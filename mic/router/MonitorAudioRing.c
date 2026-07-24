//
//  MonitorAudioRing.c
//
//  See MonitorAudioRing.h. Lock-free SPSC: the producer owns writeIndex, the consumer owns
//  readIndex. The consumer is the ONLY writer of readIndex (it does the overflow drop too),
//  so no CAS is needed. Aligned 64-bit atomics carry the indices with acquire/release so the
//  consumer sees the producer's ring stores.
//
#include "MonitorAudioRing.h"

#include <stdatomic.h>
#include <string.h>

// Power-of-two capacity so the wrap is a cheap mask. 131072 frames ≈ 2.73 s @ 48 kHz — far
// larger than any sane latency bound, so the producer can never lap the consumer in practice.
#define MON_CAPACITY   131072u
#define MON_MASK       (MON_CAPACITY - 1u)

static float             gRing[MON_CAPACITY];
static _Atomic uint64_t  gWriteIndex = 0;   // producer-owned
static _Atomic uint64_t  gReadIndex  = 0;   // consumer-owned
static _Atomic uint64_t  gUnderruns  = 0;
static _Atomic uint64_t  gSilence    = 0;

static uint32_t gPrimeFrames   = 4800;   // 100 ms
static uint32_t gReprimeFrames = 960;    // 20 ms (one frame) — fast recovery after a dip
static uint32_t gMaxLatency    = 48000;  // 1 s

// Consumer-only state (touched exclusively by mon_ring_read).
static int      gPrimed = 0;
static uint32_t gGate   = 4800;          // current prime target: gPrimeFrames, then gReprimeFrames

void mon_ring_configure(uint32_t primeFrames, uint32_t reprimeFrames, uint32_t maxLatencyFrames)
{
    if (primeFrames == 0) { primeFrames = 1; }
    if (primeFrames > MON_CAPACITY / 2) { primeFrames = MON_CAPACITY / 2; }
    if (reprimeFrames > primeFrames) { reprimeFrames = primeFrames; }
    if (maxLatencyFrames < primeFrames) { maxLatencyFrames = primeFrames; }
    if (maxLatencyFrames > MON_CAPACITY - 4096u) { maxLatencyFrames = MON_CAPACITY - 4096u; }
    gPrimeFrames = primeFrames;
    gReprimeFrames = reprimeFrames;
    gMaxLatency = maxLatencyFrames;
    mon_ring_reset();
}

void mon_ring_reset(void)
{
    atomic_store_explicit(&gWriteIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&gReadIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&gUnderruns, 0, memory_order_relaxed);
    atomic_store_explicit(&gSilence, 0, memory_order_relaxed);
    gPrimed = 0;
    gGate = gPrimeFrames;
    memset(gRing, 0, sizeof(gRing));
}

void mon_ring_write_int16(const int16_t *samples, size_t frameCount, float gain)
{
    if (samples == NULL) { return; }
    uint64_t w = atomic_load_explicit(&gWriteIndex, memory_order_relaxed);
    for (size_t i = 0; i < frameCount; ++i)
    {
        float v = ((float)samples[i] / 32768.0f) * gain;
        if (v > 1.0f) { v = 1.0f; } else if (v < -1.0f) { v = -1.0f; }
        gRing[(uint32_t)(w & MON_MASK)] = v;
        ++w;
    }
    // Release so the consumer's acquire-load of writeIndex sees these ring stores.
    atomic_store_explicit(&gWriteIndex, w, memory_order_release);
}

void mon_ring_read(float *out, size_t frameCount)
{
    const uint64_t w = atomic_load_explicit(&gWriteIndex, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&gReadIndex, memory_order_relaxed);

    // Overflow: bound latency by dropping the oldest samples the producer got ahead of us.
    uint64_t available = w - r;
    if (available > gMaxLatency)
    {
        r = w - gMaxLatency;
        available = gMaxLatency;
    }

    // Prime gate: hold silence until the buffer has enough to ride out normal burst jitter.
    if (!gPrimed)
    {
        if (available >= gGate)
        {
            gPrimed = 1;
        }
        else
        {
            memset(out, 0, frameCount * sizeof(float));
            atomic_fetch_add_explicit(&gSilence, frameCount, memory_order_relaxed);
            atomic_store_explicit(&gReadIndex, r, memory_order_release);
            return;
        }
    }

    size_t i = 0;
    for (; i < frameCount && r < w; ++i)
    {
        out[i] = gRing[(uint32_t)(r & MON_MASK)];
        ++r;
    }

    if (i < frameCount)
    {
        // Underrun: fill the rest with silence and re-arm the gate cheaply so a transient
        // dip does not cost a full re-prime of silence.
        memset(out + i, 0, (frameCount - i) * sizeof(float));
        atomic_fetch_add_explicit(&gUnderruns, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&gSilence, (uint64_t)(frameCount - i), memory_order_relaxed);
        gPrimed = 0;
        gGate = gReprimeFrames;
    }

    atomic_store_explicit(&gReadIndex, r, memory_order_release);
}

uint64_t mon_ring_underruns(void)      { return atomic_load_explicit(&gUnderruns, memory_order_relaxed); }
uint64_t mon_ring_silence_frames(void) { return atomic_load_explicit(&gSilence, memory_order_relaxed); }
uint64_t mon_ring_write_index(void)    { return atomic_load_explicit(&gWriteIndex, memory_order_relaxed); }
uint64_t mon_ring_read_index(void)     { return atomic_load_explicit(&gReadIndex, memory_order_relaxed); }
