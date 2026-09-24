#ifndef OB_ENGINE_H
#define OB_ENGINE_H
#include "OBSignal.h"
#include <CoreAudio/CoreAudio.h>
enum { OB_CALLBACK_BUCKETS = 128, OB_CALLBACK_BUCKET_US = 1 };
typedef struct OBEngine OBEngine;
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
OBEngineStats ob_engine_stats(OBEngine *engine);
#endif
