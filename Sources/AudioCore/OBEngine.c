#include "OBEngine.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_FRAMES = 8192 };
struct OBEngine {
  AudioUnit input, output;
  OBSignal *signal;
  float capture[MAX_FRAMES * 2];
  _Atomic int32_t error;
  _Atomic uint64_t callback_max_ticks;
};
static void failure(OBEngine *e, OSStatus status) {
  int32_t expected = 0;
  atomic_compare_exchange_strong(&e->error, &expected, status);
}
static OSStatus capture(void *context, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 n,
                        AudioBufferList *unused) {
  OBEngine *e = context;
  if (n > MAX_FRAMES) {
    failure(e, kAudioUnitErr_TooManyFramesToProcess);
    return noErr;
  }
  AudioBufferList b = {1, {{2, n * 8, e->capture}}};
  OSStatus status = AudioUnitRender(e->input, flags, time, 1, n, &b);
  if (status) {
    failure(e, status);
    return noErr;
  }
  ob_signal_push(e->signal, e->capture, n);
  return noErr;
}
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 n,
                       AudioBufferList *buffers) {
  OBEngine *e = context;
  uint64_t start = mach_absolute_time();
  if (n > MAX_FRAMES || buffers->mNumberBuffers != 1 ||
      buffers->mBuffers[0].mNumberChannels != 2 ||
      buffers->mBuffers[0].mDataByteSize < n * 8) {
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
      if (buffers->mBuffers[i].mData)
        memset(buffers->mBuffers[i].mData, 0,
               buffers->mBuffers[i].mDataByteSize);
    failure(e, kAudioUnitErr_FormatNotSupported);
    return noErr;
  }
  ob_signal_render(e->signal, buffers->mBuffers[0].mData, n);
  uint64_t elapsed = mach_absolute_time() - start;
  if (elapsed >
      atomic_load_explicit(&e->callback_max_ticks, memory_order_relaxed))
    atomic_store_explicit(&e->callback_max_ticks, elapsed,
                          memory_order_relaxed);
  return noErr;
}
static OSStatus setup(OBEngine *e, AudioUnit *unit, AudioDeviceID device,
                      bool input) {
  AudioComponentDescription d = {kAudioUnitType_Output,
                                 kAudioUnitSubType_HALOutput,
                                 kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent c = AudioComponentFindNext(NULL, &d);
  if (!c)
    return kAudioUnitErr_InvalidProperty;
  OSStatus status = AudioComponentInstanceNew(c, unit);
  if (status)
    return status;
  UInt32 on = 1, off = 0, max = MAX_FRAMES;
#define CHECK(call)                                                            \
  do {                                                                         \
    status = (call);                                                           \
    if (status)                                                                \
      return status;                                                           \
  } while (0)
  CHECK(AudioUnitSetProperty(*unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, input ? &on : &off,
                             sizeof(on)));
  CHECK(AudioUnitSetProperty(*unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, input ? &off : &on,
                             sizeof(on)));
  CHECK(AudioUnitSetProperty(*unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &device,
                             sizeof(device)));
  AudioStreamBasicDescription hardware;
  UInt32 size = sizeof(hardware);
  CHECK(AudioUnitGetProperty(*unit, kAudioUnitProperty_StreamFormat,
                             input ? kAudioUnitScope_Input
                                   : kAudioUnitScope_Output,
                             input ? 1 : 0, &hardware, &size));
  if (hardware.mSampleRate != 48000 || hardware.mChannelsPerFrame != 2)
    return kAudioUnitErr_FormatNotSupported;
  AudioStreamBasicDescription pcm = {48000,
                                     kAudioFormatLinearPCM,
                                     kAudioFormatFlagIsFloat |
                                         kAudioFormatFlagIsPacked |
                                         kAudioFormatFlagsNativeEndian,
                                     8,
                                     1,
                                     8,
                                     2,
                                     32,
                                     0};
  CHECK(AudioUnitSetProperty(*unit, kAudioUnitProperty_StreamFormat,
                             input ? kAudioUnitScope_Output
                                   : kAudioUnitScope_Input,
                             input ? 1 : 0, &pcm, sizeof(pcm)));
  CHECK(AudioUnitSetProperty(*unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &max, sizeof(max)));
  if (input)
    CHECK(AudioUnitSetProperty(*unit, kAudioUnitProperty_ShouldAllocateBuffer,
                               kAudioUnitScope_Output, 1, &off, sizeof(off)));
  AURenderCallbackStruct callback = {input ? capture : render, e};
  CHECK(AudioUnitSetProperty(*unit,
                             input ? kAudioOutputUnitProperty_SetInputCallback
                                   : kAudioUnitProperty_SetRenderCallback,
                             input ? kAudioUnitScope_Global
                                   : kAudioUnitScope_Input,
                             0, &callback, sizeof(callback)));
  CHECK(AudioUnitInitialize(*unit));
#undef CHECK
  return noErr;
}
OBEngine *ob_engine_create(AudioDeviceID input, AudioDeviceID output,
                           OSStatus *error) {
  if (!error)
    return NULL;
  OBEngine *e = calloc(1, sizeof(*e));
  if (!e) {
    *error = kAudioHardwareUnspecifiedError;
    return NULL;
  }
  e->signal = ob_signal_create();
  if (!e->signal) {
    free(e);
    *error = kAudioHardwareUnspecifiedError;
    return NULL;
  }
  *error = setup(e, &e->input, input, true);
  if (!*error)
    *error = setup(e, &e->output, output, false);
  if (*error) {
    ob_engine_destroy(e);
    return NULL;
  }
  return e;
}
OSStatus ob_engine_start(OBEngine *e) {
  OSStatus s = AudioOutputUnitStart(e->input);
  if (s)
    return s;
  s = AudioOutputUnitStart(e->output);
  if (s)
    AudioOutputUnitStop(e->input);
  return s;
}
void ob_engine_destroy(OBEngine *e) {
  if (!e)
    return;
  if (e->output) {
    AudioOutputUnitStop(e->output);
    AudioUnitUninitialize(e->output);
    AudioComponentInstanceDispose(e->output);
  }
  if (e->input) {
    AudioOutputUnitStop(e->input);
    AudioUnitUninitialize(e->input);
    AudioComponentInstanceDispose(e->input);
  }
  ob_signal_destroy(e->signal);
  free(e);
}
void ob_engine_gain(OBEngine *e, float db, bool bypass) {
  ob_signal_gain(e->signal, db, bypass);
}
OBEngineStats ob_engine_stats(OBEngine *e) {
  return (OBEngineStats){ob_signal_stats(e->signal), atomic_load(&e->error),
                         atomic_load(&e->callback_max_ticks)};
}
