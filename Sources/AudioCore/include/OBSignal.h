#ifndef OB_SIGNAL_H
#define OB_SIGNAL_H
#include "OBDSP.h"
#include <stdbool.h>
#include <stdint.h>

typedef struct OBSignal OBSignal;
typedef struct {
  float input_peak, output_peak;
  float compressor_reduction, limiter_reduction;
  // Latest rendered block peaks without the display release envelope.
  float input_raw_peak, output_raw_peak;
  float de_esser_reduction, de_popper_reduction;
  float input_left, input_right, output_left, output_right;
} OBMeterValues;
typedef struct {
  // Display envelopes with immediate attack and 200 dB/s release, not raw block peaks.
  float input_peak, output_peak;
  uint64_t underruns, overruns, clipped_samples, output_frames;
  uint32_t buffered_frames;
  OBDSPStats dsp;
  uint64_t advanced_late_frames, advanced_deadline_misses;
} OBSignalStats;

// Single capture producer and single output consumer. Reset only while stopped.
OBSignal *ob_signal_create(void);
bool ob_signal_advanced(OBSignal *signal, OBAdvancedNR processor, uint32_t maximum_callback_frames);
bool ob_signal_processing(OBSignal *signal, const float *values, uint32_t count, float decibels);
bool ob_signal_failed(OBSignal *signal);
uint32_t ob_signal_latency(OBSignal *signal);
void ob_signal_destroy(OBSignal *signal);
void ob_signal_reset(OBSignal *signal);
// Set while stopped, using the input device buffer size read back from Core Audio.
bool ob_signal_set_input_frames(OBSignal *signal, uint32_t frames);
bool ob_signal_push(OBSignal *signal, const float *stereo, uint32_t frames);
// Publish valid device sample/host timestamp pairs (host in seconds).
// Each function belongs to its corresponding callback; both are bounded and
// allocation-free. Reset and route reconstruction discard clock history.
void ob_signal_input_time(OBSignal *signal, double sample, double host);
void ob_signal_output_time(OBSignal *signal, double sample, double host);
void ob_signal_render(OBSignal *signal, float *stereo, uint32_t frames);
OBSignalStats ob_signal_stats(OBSignal *signal);
OBMeterValues ob_signal_meters(OBSignal *signal);
#endif
