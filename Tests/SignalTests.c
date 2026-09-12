#include "OBLoopback.h"
#include "OBSignal.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static void drift(double ppm, unsigned input_block, unsigned output_block) {
  OBSignal *s = ob_signal_create();
  assert(s);
  float in[2048], out[2048];
  double next_input = 0, next_output = 0;
  double previous_jitter = 0;
  unsigned callback = 0;
  uint64_t captured = 0;
  for (;;) {
    if (next_input < next_output) {
      if (next_input > 120)
        break;
      for (unsigned i = 0; i < input_block; ++i) {
        in[i * 2] = 0.2f * sinf((captured + i) * 2 * M_PI * 997 / 48000);
        in[i * 2 + 1] = 0.1f * sinf((captured + i) * 2 * M_PI * 1733 / 48000);
      }
      assert(ob_signal_push(s, in, input_block));
      captured += input_block;
      double jitter = (++callback % 2 ? 0.0005 : -0.0005);
      next_input += (double)input_block / (48000 * (1 + ppm / 1e6)) + jitter -
                    previous_jitter;
      previous_jitter = jitter;
    } else {
      ob_signal_render(s, out, output_block);
      for (unsigned i = 0; i < output_block * 2; ++i)
        assert(isfinite(out[i]) && fabsf(out[i]) <= 1);
      next_output += (double)output_block / 48000;
    }
  }
  OBSignalStats stats = ob_signal_stats(s);
  printf("drift %.0f ppm, %u/%u frames: underruns=%llu overruns=%llu fill=%u\n",
         ppm, input_block, output_block, (unsigned long long)stats.underruns,
         (unsigned long long)stats.overruns, stats.buffered_frames);
  assert(stats.underruns == 0 && stats.overruns == 0 &&
         stats.output_frames > 48000 * 119);
  assert(stats.buffered_frames > 16 && stats.buffered_frames < 4096);
  ob_signal_destroy(s);
}
static void gain(void) {
  OBSignal *s = ob_signal_create();
  float in[1024], out[1024];
  for (unsigned i = 0; i < 512; ++i) {
    in[2 * i] = 0.2f;
    in[2 * i + 1] = -0.1f;
  }
  assert(ob_signal_push(s, in, 512));
  assert(ob_signal_push(s, in, 512));
  assert(ob_signal_push(s, in, 512));
  ob_signal_gain(s, 6.0206f, false);
  for (unsigned b = 0; b < 40; ++b) {
    assert(ob_signal_push(s, in, 512));
    ob_signal_render(s, out, 512);
  }
  assert(fabs(out[100] - 0.4) < 0.00001 && fabs(out[101] + 0.2) < 0.00001);
  ob_signal_gain(s, 0, true);
  for (unsigned b = 0; b < 40; ++b) {
    assert(ob_signal_push(s, in, 512));
    ob_signal_render(s, out, 512);
  }
  assert(fabs(out[100] - 0.2) < 0.00001 && fabs(out[101] + 0.1) < 0.00001);
  ob_signal_gain(s, NAN, false);
  assert(ob_signal_push(s, in, 512));
  ob_signal_render(s, out, 512);
  assert(fabs(out[100] - 0.2) < 0.00001);
  ob_signal_destroy(s);
}
static OBLoopback ring;
static void meters(void) {
  OBSignal *s = ob_signal_create();
  float in[960], out[960];
  for (unsigned i = 0; i < 960; ++i) in[i] = 0.75f;
  for (unsigned i = 0; i < 4; ++i) assert(ob_signal_push(s, in, 480));
  for (unsigned i = 0; i < 20; ++i) {
    assert(ob_signal_push(s, in, 480));
    ob_signal_render(s, out, 480);
  }
  assert(fabsf(ob_signal_stats(s).output_peak - 0.75f) < 0.00001f);
  memset(in, 0, sizeof(in));
  // Even after the audible peak is gone, intervening silent blocks must not
  // erase it before a UI read. The old latest-block-only meter fails here.
  for (unsigned i = 0; i < 8; ++i) {
    assert(ob_signal_push(s, in, 480));
    ob_signal_render(s, out, 480);
  }
  for (unsigned i = 0; i < 960; ++i) assert(out[i] == 0);
  float peak = ob_signal_stats(s).output_peak;
  assert(peak > 0.01f && peak < 0.75f);
  for (unsigned i = 0; i < 30; ++i) {
    assert(ob_signal_push(s, in, 480));
    ob_signal_render(s, out, 480);
  }
  // A 300 ms silence interval lowers the display by 60 dB, rather than
  // leaving the previous speech peak visible for several seconds.
  assert(fabsf(20 * log10f(ob_signal_stats(s).output_peak / peak) + 60) < 0.001f);
  for (unsigned i = 0; i < 960; ++i) in[i] = 0.9f;
  bool rose = false;
  for (unsigned i = 0; i < 8; ++i) {
    assert(ob_signal_push(s, in, 480));
    ob_signal_render(s, out, 480);
    float block_peak = 0;
    for (unsigned j = 0; j < 960; ++j) block_peak = fmaxf(block_peak, fabsf(out[j]));
    if (block_peak > 0.8f) {
      assert(ob_signal_stats(s).output_peak >= block_peak);
      rose = true;
      break;
    }
  }
  assert(rose);
  ob_signal_reset(s);
  assert(ob_signal_stats(s).input_peak == 0 && ob_signal_stats(s).output_peak == 0);
  ob_signal_destroy(s);
}
static void starvation(void) {
  OBSignal *s = ob_signal_create();
  assert(s);
  float in[512], out[512];
  for (unsigned i = 0; i < 512; ++i)
    in[i] = 0.25f;
  for (unsigned i = 0; i < 8; ++i)
    assert(ob_signal_push(s, in, 256));
  for (unsigned i = 0; i < 20; ++i)
    ob_signal_render(s, out, 256);
  assert(ob_signal_stats(s).underruns == 1);
  // Repeated reads must remain silent until enough NEW samples arrive.
  for (unsigned i = 0; i < 512; ++i)
    assert(out[i] == 0);
  for (unsigned i = 0; i < 512; ++i) in[i] = -0.25f;
  for (unsigned i = 0; i < 8; ++i)
    assert(ob_signal_push(s, in, 256));
  ob_signal_render(s, out, 256);
  // Recovery must not replay samples retained by the new DSP delay line.
  for (unsigned i = 0; i < 512; ++i) assert(out[i] == 0);
  for (unsigned b = 0; b < 8; ++b) {
    assert(ob_signal_push(s, in, 256));
    ob_signal_render(s, out, 256);
  }
  assert(fabsf(out[100] + 0.25f) < 0.00001f);
  assert(ob_signal_stats(s).underruns == 1);
  ob_signal_destroy(s);
}
static void loopback(void) {
  float in[1024], a[1024], b[1024];
  for (unsigned i = 0; i < 1024; ++i)
    in[i] = (float)i / 1024;
  ob_loop_clear(&ring);
  ob_loop_read(&ring, 0, a, 512);
  for (unsigned i = 0; i < 1024; ++i)
    assert(a[i] == 0);
  ob_loop_write(&ring, 12345, in, 512);
  ob_loop_read(&ring, 12345 + OB_LOOP_DELAY, a, 512);
  ob_loop_read(&ring, 12345 + OB_LOOP_DELAY, b, 512);
  assert(!memcmp(in, a, sizeof(in)) && !memcmp(a, b, sizeof(a)));
  ob_loop_write(&ring, 12345 + OB_LOOP_CAPACITY, in, 512);
  ob_loop_read(&ring, 12345 + OB_LOOP_DELAY, a, 512);
  for (unsigned i = 0; i < 1024; ++i)
    assert(a[i] == 0);
}
static void *writer(void *unused) {
  float in[256];
  for (unsigned i = 0; i < 256; ++i)
    in[i] = i % 2 ? -.25f : .25f;
  for (unsigned i = 0; i < 30000; ++i)
    ob_loop_write(&ring, i * 128, in, 128);
  return NULL;
}
static void *reader(void *unused) {
  float out[256];
  for (unsigned i = 0; i < 30000; ++i) {
    ob_loop_read(&ring, i * 128 + OB_LOOP_DELAY, out, 128);
    for (unsigned j = 0; j < 128; ++j)
      assert((out[2 * j] == 0 && out[2 * j + 1] == 0) ||
             (out[2 * j] == .25f && out[2 * j + 1] == -.25f));
  }
  return NULL;
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--starvation")) { starvation(); return 0; }
  gain();
  meters();
  loopback();
  starvation();
  ob_loop_clear(&ring);
  pthread_t w, r1, r2;
  pthread_create(&w, NULL, writer, NULL);
  pthread_create(&r1, NULL, reader, NULL);
  pthread_create(&r2, NULL, reader, NULL);
  pthread_join(w, NULL);
  pthread_join(r1, NULL);
  pthread_join(r2, NULL);
  drift(-1000, 512, 256);
  drift(1000, 256, 512);
  drift(0, 128, 128);
  puts("PASS signal, drift, timestamp loopback and simultaneous readers");
}
