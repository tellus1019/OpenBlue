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
} OBMeterValues;
typedef struct {
  // Display envelopes with immediate attack and 200 dB/s release, not raw block peaks.
  float input_peak, output_peak;
  uint64_t underruns, overruns, clipped_samples, output_frames;
  uint32_t buffered_frames;
  OBDSPStats dsp;
} OBSignalStats;

// Single capture producer and single output consumer. Reset only while stopped.
OBSignal *ob_signal_create(void);
bool ob_signal_advanced(OBSignal *signal, OBAdvancedNR processor, uint32_t maximum_callback_frames);
bool ob_signal_processing(OBSignal *signal, const float *values, uint32_t count, float decibels);
bool ob_signal_failed(OBSignal *signal);
uint32_t ob_signal_latency(OBSignal *signal);
void ob_signal_destroy(OBSignal *signal);
void ob_signal_reset(OBSignal *signal);
void ob_signal_gain(OBSignal *signal, float decibels, bool bypass);
bool ob_signal_parameters(OBSignal *signal, const float *values, uint32_t count);
bool ob_signal_push(OBSignal *signal, const float *stereo, uint32_t frames);
void ob_signal_render(OBSignal *signal, float *stereo, uint32_t frames);
OBSignalStats ob_signal_stats(OBSignal *signal);
OBMeterValues ob_signal_meters(OBSignal *signal);
#endif
