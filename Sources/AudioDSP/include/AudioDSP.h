#ifndef AUDIO_DSP_H
#define AUDIO_DSP_H
#include <stdint.h>
#include <stdbool.h>
typedef struct VDSP VDSP;
VDSP *vdsp_create(void);
void vdsp_destroy(VDSP *s);
void vdsp_set_gain(VDSP *s, float gain, bool muted);
void vdsp_process(VDSP *s, const float *input, uint32_t inputCount, float *output, uint32_t outputCount);
void vdsp_stereo_to_mono(VDSP *s, const float *input, uint32_t inputFrames, float *output, uint32_t outputFrames);
void vdsp_format_mismatch(VDSP *s);
uint32_t vdsp_underruns(VDSP *s);
uint32_t vdsp_overruns(VDSP *s);
uint32_t vdsp_input_frames(VDSP *s);
uint32_t vdsp_output_frames(VDSP *s);
uint32_t vdsp_callbacks(VDSP *s);
float vdsp_input_peak(VDSP *s);
float vdsp_output_peak(VDSP *s);
// Single producer and single consumer; counts are interleaved stereo frames.
typedef struct VAudioRing VAudioRing;
VAudioRing *vaudio_ring_create(uint32_t capacityFrames);
void vaudio_ring_destroy(VAudioRing *ring);
uint32_t vaudio_ring_write(VAudioRing *ring, const float *input, uint32_t frames);
uint32_t vaudio_ring_read(VAudioRing *ring, float *output, uint32_t frames);
uint32_t vaudio_ring_available(VAudioRing *ring);
uint64_t vaudio_ring_underruns(VAudioRing *ring);
uint64_t vaudio_ring_overruns(VAudioRing *ring);
#endif
