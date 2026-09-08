#ifndef OB_ENGINE_H
#define OB_ENGINE_H
#include "OBSignal.h"
#include <CoreAudio/CoreAudio.h>
typedef struct OBEngine OBEngine;
typedef struct {
  OBSignalStats signal;
  OSStatus error;
  uint64_t callback_max_ticks;
} OBEngineStats;
// Control functions are serialized by the app. Callbacks only access audio
// state.
OBEngine *ob_engine_create(AudioDeviceID input, AudioDeviceID output,
                           OSStatus *error);
OSStatus ob_engine_start(OBEngine *engine);
void ob_engine_destroy(OBEngine *engine);
void ob_engine_gain(OBEngine *engine, float db, bool bypass);
OBEngineStats ob_engine_stats(OBEngine *engine);
#endif
