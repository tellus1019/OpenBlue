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
  AudioTimeStamp time = {0};
  AudioUnitRenderActionFlags flags = 0;
  float output[512];
  AudioBufferList buffers = {1, {{2, sizeof(output), output}}};
  // Output callbacks alone are not proof of captured or processed input.
  assert(render(&engine, &flags, &time, 0, 256, &buffers) == noErr);
  OBEngineStats stats = ob_engine_stats(&engine);
  assert(stats.render_frames == 256 && stats.captured_frames == 0 &&
         stats.signal.output_frames == 0);
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
  ob_signal_destroy(engine.signal);
  puts("PASS capture, DSP and render progress diagnostics; no device opened");
  return 0;
}
