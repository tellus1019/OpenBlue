#include "OBDSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static float uniform(unsigned *seed) {
  *seed = *seed*1664525u + 1013904223u;
  return ((*seed>>8)/8388608.f-1)*1.7320508f;
}
static void noise_and_onset(float sensitivity, float bias, float release) {
  OBDSP *s = ob_dsp_create();
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
  v[OBP_NR_ON] = 1; v[OBP_NR_RANGE] = 18;
  v[OBP_NR_SENSITIVITY] = sensitivity; v[OBP_NR_BIAS] = bias;
  v[OBP_NR_RELEASE] = release;
  assert(ob_dsp_update(s, v, OBP_COUNT)); ob_dsp_reset(s);
  unsigned seed = 91;
  double in_noise = 0, out_noise = 0, onset = 0, expected = 0;
  float noise_history[OB_DSP_LATENCY] = {0}, colored = 0;
  for (unsigned i = 0; i < 240000; ++i) {
    // Colored background followed by a quiet voiced onset. No device is opened.
    colored = .85f*colored + .15f*uniform(&seed);
    float noise = .003f*colored;
    float reference_noise = noise_history[i%OB_DSP_LATENCY];
    noise_history[i%OB_DSP_LATENCY] = noise;
    float tone = i >= 144000 && i < 192000 ? .015f*sinf(2*M_PI*997*i/48000) : 0;
    float audio[] = {noise+tone, -.5f*(noise+tone)};
    ob_dsp_process(s, audio, 1);
    assert(isfinite(audio[0]) && isfinite(audio[1]));
    assert(fabsf(audio[1]+.5f*audio[0]) < 1e-6f);
    int source = (int)i-OB_DSP_LATENCY;
    if (source >= 96000 && source < 144000) {
      in_noise += reference_noise*reference_noise; out_noise += audio[0]*audio[0];
    }
    if (source >= 144000 && source < 145440) {
      double wave = sin(2*M_PI*997*source/48000);
      onset += audio[0]*wave; expected += .015*wave*wave;
    }
  }
  double reduction = 10*log10(out_noise/in_noise), onset_db = 20*log10(fabs(onset/expected));
  printf("NR sensitivity=%.0f bias=%.0f release=%.0f: background=%.2f dB, first 30 ms voice=%.2f dB\n",
         sensitivity, bias, release, reduction, onset_db);
  assert(reduction < -3 && reduction > -19);
  assert(onset_db > -2 && onset_db < 1);
  ob_dsp_destroy(s);
}
int main(void) {
  noise_and_onset(6, 1, 100);
  noise_and_onset(6, 1, 1000);
  noise_and_onset(0, 0, 0);
  noise_and_onset(40, 5, 1000);
  puts("PASS colored-noise learning, voiced onset, release and linked stereo");
}
