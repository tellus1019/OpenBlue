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
  _Atomic uint64_t captured_frames, render_frames;
  bool profiling;
  uint64_t ticks_per_second;
  uint64_t ticks_per_bucket;
  _Atomic uint64_t input_callbacks, input_total_ticks, input_max_ticks;
  _Atomic uint64_t output_callbacks, output_total_ticks, output_budget_exceeded;
  _Atomic uint32_t output_min_frames, output_max_frames;
  _Atomic uint64_t output_duration_buckets[OB_CALLBACK_BUCKETS];
};
static void update_max(_Atomic uint64_t *maximum, uint64_t value) {
  uint64_t previous = atomic_load_explicit(maximum, memory_order_relaxed);
  while (value > previous &&
         !atomic_compare_exchange_weak_explicit(maximum, &previous, value,
                                                memory_order_relaxed,
                                                memory_order_relaxed)) {}
}
static void record_input(OBEngine *e, uint64_t started) {
  if (!e->profiling) return;
  uint64_t elapsed = mach_absolute_time() - started;
  atomic_fetch_add_explicit(&e->input_callbacks, 1, memory_order_relaxed);
  atomic_fetch_add_explicit(&e->input_total_ticks, elapsed, memory_order_relaxed);
  update_max(&e->input_max_ticks, elapsed);
}
static void record_output(OBEngine *e, uint64_t started, UInt32 frames) {
  uint64_t elapsed = mach_absolute_time() - started;
  update_max(&e->callback_max_ticks, elapsed);
  if (!e->profiling) return;
  atomic_fetch_add_explicit(&e->output_callbacks, 1, memory_order_relaxed);
  atomic_fetch_add_explicit(&e->output_total_ticks, elapsed, memory_order_relaxed);
  uint32_t minimum = atomic_load_explicit(&e->output_min_frames,
                                           memory_order_relaxed);
  while ((!minimum || frames < minimum) &&
         !atomic_compare_exchange_weak_explicit(&e->output_min_frames,
                                                &minimum, frames,
                                                memory_order_relaxed,
                                                memory_order_relaxed)) {}
  uint32_t maximum = atomic_load_explicit(&e->output_max_frames,
                                           memory_order_relaxed);
  while (frames > maximum &&
         !atomic_compare_exchange_weak_explicit(&e->output_max_frames,
                                                &maximum, frames,
                                                memory_order_relaxed,
                                                memory_order_relaxed)) {}
  if (e->ticks_per_second &&
      elapsed > ((uint64_t)frames * e->ticks_per_second) / 48000)
    atomic_fetch_add_explicit(&e->output_budget_exceeded, 1,
                              memory_order_relaxed);
  if (e->ticks_per_bucket) {
    uint64_t bucket = elapsed / e->ticks_per_bucket;
    if (bucket >= OB_CALLBACK_BUCKETS) bucket = OB_CALLBACK_BUCKETS - 1;
    atomic_fetch_add_explicit(&e->output_duration_buckets[bucket], 1,
                              memory_order_relaxed);
  }
}
static void failure(OBEngine *e, OSStatus status) {
  int32_t expected = 0;
  atomic_compare_exchange_strong(&e->error, &expected, status);
}
static OSStatus capture(void *context, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 n,
                        AudioBufferList *unused) {
  OBEngine *e = context;
  uint64_t started = e->profiling ? mach_absolute_time() : 0;
  if (n > MAX_FRAMES) {
    failure(e, kAudioUnitErr_TooManyFramesToProcess);
    record_input(e, started);
    return noErr;
  }
  AudioBufferList b = {1, {{2, n * 8, e->capture}}};
  OSStatus status = AudioUnitRender(e->input, flags, time, 1, n, &b);
  if (status) {
    failure(e, status);
    record_input(e, started);
    return noErr;
  }
  atomic_fetch_add_explicit(&e->captured_frames, n, memory_order_relaxed);
  ob_signal_push(e->signal, e->capture, n);
  record_input(e, started);
  return noErr;
}
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 n,
                       AudioBufferList *buffers) {
  OBEngine *e = context;
  uint64_t started = mach_absolute_time();
  if (n > MAX_FRAMES || buffers->mNumberBuffers != 1 ||
      buffers->mBuffers[0].mNumberChannels != 2 ||
      buffers->mBuffers[0].mDataByteSize < n * 8) {
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
      if (buffers->mBuffers[i].mData)
        memset(buffers->mBuffers[i].mData, 0,
               buffers->mBuffers[i].mDataByteSize);
    failure(e, kAudioUnitErr_FormatNotSupported);
    record_output(e, started, n);
    return noErr;
  }
  ob_signal_render(e->signal, buffers->mBuffers[0].mData, n);
  atomic_fetch_add_explicit(&e->render_frames, n, memory_order_relaxed);
  record_output(e, started, n);
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
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer) {
    e->ticks_per_second = 1000000000ull * timebase.denom / timebase.numer;
    e->ticks_per_bucket = (uint64_t)OB_CALLBACK_BUCKET_US * 1000 *
                          timebase.denom / timebase.numer;
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
bool ob_engine_parameters(OBEngine *e, const float *v, uint32_t n) {
  return ob_signal_parameters(e->signal, v, n);
}
void ob_engine_set_profiling(OBEngine *e, bool enabled) {
  e->profiling = enabled;
}
OSStatus ob_engine_error(OBEngine *e) {
  return atomic_load_explicit(&e->error, memory_order_relaxed);
}
OBMeterValues ob_engine_meters(OBEngine *e) {
  return ob_signal_meters(e->signal);
}
OBEngineDiagnostics ob_engine_diagnostics(OBEngine *e) {
  return (OBEngineDiagnostics){
      ob_signal_stats(e->signal), ob_engine_error(e),
      atomic_load_explicit(&e->callback_max_ticks, memory_order_relaxed),
      atomic_load_explicit(&e->captured_frames, memory_order_relaxed),
      atomic_load_explicit(&e->render_frames, memory_order_relaxed)};
}
OBEngineStats ob_engine_stats(OBEngine *e) {
  OBEngineStats stats = {0};
  stats.signal = ob_signal_stats(e->signal);
  stats.error = atomic_load(&e->error);
  stats.callback_max_ticks = atomic_load(&e->callback_max_ticks);
  stats.captured_frames = atomic_load(&e->captured_frames);
  stats.render_frames = atomic_load(&e->render_frames);
  stats.input_callbacks = atomic_load(&e->input_callbacks);
  stats.input_total_ticks = atomic_load(&e->input_total_ticks);
  stats.input_max_ticks = atomic_load(&e->input_max_ticks);
  stats.output_callbacks = atomic_load(&e->output_callbacks);
  stats.output_total_ticks = atomic_load(&e->output_total_ticks);
  stats.output_budget_exceeded = atomic_load(&e->output_budget_exceeded);
  stats.output_min_frames = atomic_load(&e->output_min_frames);
  stats.output_max_frames = atomic_load(&e->output_max_frames);
  for (unsigned i = 0; i < OB_CALLBACK_BUCKETS; ++i)
    stats.output_duration_buckets[i] =
        atomic_load(&e->output_duration_buckets[i]);
  return stats;
}
