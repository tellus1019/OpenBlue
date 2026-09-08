#ifndef OB_SIGNAL_H
#define OB_SIGNAL_H
#include <stdbool.h>
#include <stdint.h>

typedef struct OBSignal OBSignal;
typedef struct {
  // Display envelopes with immediate attack and 24 dB/s release, not raw block peaks.
  float input_peak, output_peak;
  uint64_t underruns, overruns, clipped_samples, output_frames;
  uint32_t buffered_frames;
} OBSignalStats;

// Single capture producer and single output consumer. Reset only while stopped.
OBSignal *ob_signal_create(void);
void ob_signal_destroy(OBSignal *signal);
void ob_signal_reset(OBSignal *signal);
void ob_signal_gain(OBSignal *signal, float decibels, bool bypass);
bool ob_signal_push(OBSignal *signal, const float *stereo, uint32_t frames);
void ob_signal_render(OBSignal *signal, float *stereo, uint32_t frames);
OBSignalStats ob_signal_stats(OBSignal *signal);
#endif
