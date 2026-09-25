// Exercise the real callbacks without opening an audio device.
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stdio.h>
static OSStatus simulated_status;
static OSStatus simulated_render(AudioUnit unit, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
  if (simulated_status) return simulated_status;
  float *out = buffers->mBuffers[0].mData;
  for (UInt32 i = 0; i < frames * 2; ++i) out[i] = 0.25f;
  return noErr;
}
#define AudioUnitRender simulated_render
#include "../Sources/AudioCore/OBEngine.c"
#undef AudioUnitRender

int main(void) {
  OBEngine engine = {0};
  engine.signal = ob_signal_create();
  assert(engine.signal);
  ob_engine_set_profiling(&engine, true);
  mach_timebase_info_data_t timebase;
  assert(mach_timebase_info(&timebase) == KERN_SUCCESS);
  engine.ticks_per_second = 1000000000ull * timebase.denom / timebase.numer;
  engine.ticks_per_bucket = (uint64_t)OB_CALLBACK_BUCKET_US * 1000 *
                            timebase.denom / timebase.numer;
  AudioTimeStamp time = {0};
  AudioUnitRenderActionFlags flags = 0;
  float output[512];
  AudioBufferList buffers = {1, {{2, sizeof(output), output}}};
  // Output callbacks alone are not proof of captured or processed input.
  assert(render(&engine, &flags, &time, 0, 256, &buffers) == noErr);
  OBEngineStats stats = ob_engine_stats(&engine);
  assert(stats.render_frames == 256 && stats.captured_frames == 0 &&
         stats.signal.output_frames == 0);
  assert(stats.output_callbacks == 1 && stats.input_callbacks == 0);
  for (unsigned i = 0; i < 8; ++i)
    assert(capture(&engine, &flags, &time, 1, 256, NULL) == noErr);
  assert(render(&engine, &flags, &time, 0, 256, &buffers) == noErr);
  stats = ob_engine_stats(&engine);
  assert(stats.captured_frames == 2048 && stats.render_frames == 512 &&
         stats.signal.output_frames == 256);
  // DSP has a declared fixed delay; callback progress precedes audible output.
  assert(output[0] == 0);
  for (unsigned i = 0; i < 8; ++i) {
    assert(capture(&engine, &flags, &time, 1, 256, NULL) == noErr);
    assert(render(&engine, &flags, &time, 0, 256, &buffers) == noErr);
  }
  assert(fabsf(output[0] - 0.25f) < 0.0001f);
  uint64_t before_failure = ob_engine_stats(&engine).captured_frames;
  // Failed acquisition must not advance the successful-capture counter.
  simulated_status = kAudioHardwareBadDeviceError;
  assert(capture(&engine, &flags, &time, 1, 256, NULL) == noErr);
  stats = ob_engine_stats(&engine);
  assert(stats.captured_frames == before_failure && stats.error == simulated_status);
  assert(stats.input_callbacks == 17 && stats.output_callbacks == 10);
  assert(stats.output_min_frames == 256 && stats.output_max_frames == 256);
  assert(stats.input_total_ticks >= stats.input_max_ticks);
  assert(stats.output_total_ticks >= stats.callback_max_ticks);
  uint64_t histogram_total = 0;
  for (unsigned i = 0; i < OB_CALLBACK_BUCKETS; ++i)
    histogram_total += stats.output_duration_buckets[i];
  assert(histogram_total == stats.output_callbacks);
  assert(ob_engine_error(&engine) == simulated_status);
  OBEngineDiagnostics diagnostics = ob_engine_diagnostics(&engine);
  assert(diagnostics.error == stats.error &&
         diagnostics.captured_frames == stats.captured_frames &&
         diagnostics.render_frames == stats.render_frames &&
         diagnostics.callback_max_ticks == stats.callback_max_ticks);
  OBMeterValues meters = ob_engine_meters(&engine);
  assert(meters.input_peak == stats.signal.input_peak &&
         meters.output_peak == stats.signal.output_peak &&
         meters.compressor_reduction == stats.signal.dsp.reduction_db[7] &&
         meters.limiter_reduction == stats.signal.dsp.reduction_db[8]);
  ob_signal_destroy(engine.signal);

  // Normal operation retains progress, meters and fault detection without profiling.
  OBEngine normal = {0};
  normal.signal = ob_signal_create();
  assert(normal.signal);
  simulated_status = noErr;
  for (unsigned i = 0; i < 8; ++i)
    assert(capture(&normal, &flags, &time, 1, 256, NULL) == noErr);
  assert(render(&normal, &flags, &time, 0, 256, &buffers) == noErr);
  stats = ob_engine_stats(&normal);
  diagnostics = ob_engine_diagnostics(&normal);
  meters = ob_engine_meters(&normal);
  assert(diagnostics.captured_frames == 2048 && diagnostics.render_frames == 256);
  assert(diagnostics.signal.output_frames == 256 && meters.input_peak > 0);
  assert(stats.input_callbacks == 0 && stats.output_callbacks == 0 &&
         stats.input_total_ticks == 0 && stats.output_total_ticks == 0);
  for (unsigned i = 0; i < OB_CALLBACK_BUCKETS; ++i)
    assert(stats.output_duration_buckets[i] == 0);
  simulated_status = kAudioHardwareBadDeviceError;
  assert(capture(&normal, &flags, &time, 1, 256, NULL) == noErr);
  assert(ob_engine_error(&normal) == simulated_status);
  ob_signal_destroy(normal.signal);
  puts("PASS capture, DSP and render progress diagnostics; no device opened");
  return 0;
}
