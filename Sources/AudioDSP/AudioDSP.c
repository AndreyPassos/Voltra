#include "AudioDSP.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <math.h>
struct VDSP { _Atomic(float) gain, inputPeak, outputPeak; _Atomic(uint32_t) callbacks, underruns, overruns, inputFrames, outputFrames; };
VDSP *vdsp_create(void) { VDSP *s = calloc(1, sizeof(*s)); if (s) { atomic_init(&s->gain, 1.0f); atomic_init(&s->inputPeak, 0); atomic_init(&s->outputPeak, 0); atomic_init(&s->callbacks, 0); atomic_init(&s->underruns, 0); atomic_init(&s->overruns, 0); atomic_init(&s->inputFrames, 0); atomic_init(&s->outputFrames, 0); } return s; }
void vdsp_destroy(VDSP *s) { free(s); }
void vdsp_set_gain(VDSP *s, float gain, bool muted) { if (!isfinite(gain)) gain = 1; if (gain < 0) gain = 0; if (gain > 1) gain = 1; atomic_store_explicit(&s->gain, muted ? 0 : gain, memory_order_relaxed); }
void vdsp_process(VDSP *s, const float *input, uint32_t ni, float *output, uint32_t no) { atomic_store(&s->inputFrames, ni / 2); atomic_store(&s->outputFrames, no / 2); if (ni < no) atomic_fetch_add_explicit(&s->underruns, (no-ni)/2, memory_order_relaxed); if (ni > no) atomic_fetch_add_explicit(&s->overruns, (ni-no)/2, memory_order_relaxed); float g = atomic_load_explicit(&s->gain, memory_order_relaxed); float ip = 0, op = 0; for (uint32_t i=0; i<no; i++) { float v = (input && i < ni) ? input[i] : 0; output[i] = v * g; if (fabsf(v) > ip) ip = fabsf(v); if (fabsf(output[i]) > op) op = fabsf(output[i]); } atomic_store_explicit(&s->inputPeak, ip, memory_order_relaxed); atomic_store_explicit(&s->outputPeak, op, memory_order_relaxed); atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed); }

uint32_t vdsp_callbacks(VDSP *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
float vdsp_input_peak(VDSP *s) { return atomic_load_explicit(&s->inputPeak, memory_order_relaxed); }
float vdsp_output_peak(VDSP *s) { return atomic_load_explicit(&s->outputPeak, memory_order_relaxed); }

uint32_t vdsp_underruns(VDSP *s) { return atomic_load_explicit(&s->underruns, memory_order_relaxed); }
uint32_t vdsp_overruns(VDSP *s) { return atomic_load_explicit(&s->overruns, memory_order_relaxed); }

void vdsp_stereo_to_mono(VDSP *s, const float *input, uint32_t ni, float *output, uint32_t no) {
    atomic_store(&s->inputFrames, ni); atomic_store(&s->outputFrames, no);
    if (ni < no) atomic_fetch_add_explicit(&s->underruns, no-ni, memory_order_relaxed);
    if (ni > no) atomic_fetch_add_explicit(&s->overruns, ni-no, memory_order_relaxed);
    float gain = atomic_load_explicit(&s->gain, memory_order_relaxed), ip = 0, op = 0;
    for (uint32_t i = 0; i < no; i++) {
        float v = input && i < ni ? (input[i*2] + input[i*2+1]) * 0.5f : 0;
        output[i] = v * gain;
        if (fabsf(v) > ip) ip = fabsf(v);
        if (fabsf(output[i]) > op) op = fabsf(output[i]);
    }
    atomic_store_explicit(&s->inputPeak, ip, memory_order_relaxed);
    atomic_store_explicit(&s->outputPeak, op, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
}

uint32_t vdsp_input_frames(VDSP *s) { return atomic_load(&s->inputFrames); }
uint32_t vdsp_output_frames(VDSP *s) { return atomic_load(&s->outputFrames); }

void vdsp_format_mismatch(VDSP *s) { atomic_fetch_add_explicit(&s->underruns, 1025, memory_order_relaxed); }


// The producer owns writePosition; the consumer owns readPosition.
struct VAudioRing {
    float *samples;
    uint32_t capacity;
    _Atomic(uint64_t) writePosition, readPosition, underruns, overruns;
};
VAudioRing *vaudio_ring_create(uint32_t capacity) {
    if (!capacity || (uint64_t)capacity * 2 > SIZE_MAX / sizeof(float)) return NULL;
    VAudioRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)capacity * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity;
    atomic_init(&ring->writePosition, 0);
    atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->underruns, 0);
    atomic_init(&ring->overruns, 0);
    return ring;
}
void vaudio_ring_destroy(VAudioRing *ring) { if (ring) { free(ring->samples); free(ring); } }
uint32_t vaudio_ring_write(VAudioRing *ring, const float *input, uint32_t frames) {
    if (!ring || !input) return 0;
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    uint32_t freeFrames = ring->capacity - (uint32_t)(write - read);
    uint32_t count = frames < freeFrames ? frames : freeFrames;
    for (uint32_t i = 0; i < count; ++i) {
        size_t target = (size_t)((write + i) % ring->capacity) * 2;
        ring->samples[target] = input[(size_t)i * 2];
        ring->samples[target + 1] = input[(size_t)i * 2 + 1];
    }
    atomic_fetch_add_explicit(&ring->overruns, frames - count, memory_order_relaxed);
    atomic_store_explicit(&ring->writePosition, write + count, memory_order_release);
    return count;
}
uint32_t vaudio_ring_read(VAudioRing *ring, float *output, uint32_t frames) {
    if (!ring || !output) return 0;
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    uint32_t available = (uint32_t)(write - read);
    uint32_t count = frames < available ? frames : available;
    for (uint32_t i = 0; i < frames; ++i) {
        size_t source = (size_t)((read + i) % ring->capacity) * 2;
        output[(size_t)i * 2] = i < count ? ring->samples[source] : 0;
        output[(size_t)i * 2 + 1] = i < count ? ring->samples[source + 1] : 0;
    }
    atomic_fetch_add_explicit(&ring->underruns, frames - count, memory_order_relaxed);
    atomic_store_explicit(&ring->readPosition, read + count, memory_order_release);
    return count;
}

uint32_t vaudio_ring_available(VAudioRing *ring) {
    if (!ring) return 0;
    // The two counters may advance between reads; clamp this diagnostic snapshot.
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    uint64_t count = write - read;
    return count > ring->capacity ? ring->capacity : (uint32_t)count;
}

uint64_t vaudio_ring_underruns(VAudioRing *ring) { return ring ? atomic_load_explicit(&ring->underruns, memory_order_relaxed) : 0; }
uint64_t vaudio_ring_overruns(VAudioRing *ring) { return ring ? atomic_load_explicit(&ring->overruns, memory_order_relaxed) : 0; }
