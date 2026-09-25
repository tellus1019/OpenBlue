#ifndef OB_ENGINE_H
#define OB_ENGINE_H
#include "OBSignal.h"
#include <CoreAudio/CoreAudio.h>
enum { OB_CALLBACK_BUCKETS = 128, OB_CALLBACK_BUCKET_US = 1 };
typedef struct OBEngine OBEngine;
typedef struct {
  OBSignalStats signal;
  OSStatus error;
  uint64_t callback_max_ticks, captured_frames, render_frames;
} OBEngineDiagnostics;
typedef struct {
  OBSignalStats signal;
  OSStatus error;
  uint64_t callback_max_ticks;
  uint64_t captured_frames;
  uint64_t render_frames;
  uint64_t input_callbacks, input_total_ticks, input_max_ticks;
  uint64_t output_callbacks, output_total_ticks, output_budget_exceeded;
  uint32_t output_min_frames, output_max_frames;
  uint64_t output_duration_buckets[OB_CALLBACK_BUCKETS];
} OBEngineStats;
// Control functions are serialized by the app. Callbacks only access audio
// state.
OBEngine *ob_engine_create(AudioDeviceID input, AudioDeviceID output,
                           OSStatus *error);
OSStatus ob_engine_start(OBEngine *engine);
void ob_engine_destroy(OBEngine *engine);
void ob_engine_gain(OBEngine *engine, float db, bool bypass);
bool ob_engine_parameters(OBEngine *engine, const float *values, uint32_t count);
// Configure detailed timing only while stopped. Display diagnostics remain available.
void ob_engine_set_profiling(OBEngine *engine, bool enabled);
OSStatus ob_engine_error(OBEngine *engine);
OBMeterValues ob_engine_meters(OBEngine *engine);
OBEngineDiagnostics ob_engine_diagnostics(OBEngine *engine);
OBEngineStats ob_engine_stats(OBEngine *engine);
#endif
