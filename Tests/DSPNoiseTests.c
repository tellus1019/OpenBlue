#include "OBDSP.h"
#include <Accelerate/Accelerate.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

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
static void delayed_background(void) {
  const unsigned count = 7*48000, fft_size = 512, bins = 257;
  float *input = calloc(count, sizeof(float));
  float *audio = calloc(2*(count+OB_DSP_LATENCY), sizeof(float));
  assert(input && audio);
  unsigned seed = 183;
  float colored = 0;
  for (unsigned i = 2*48000; i < count; ++i) {
    colored = .85f*colored + .15f*uniform(&seed);
    input[i] = .003f*colored;
    audio[2*i] = audio[2*i+1] = input[i];
  }
  OBDSP *s = ob_dsp_create(); assert(s);
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
  v[OBP_NR_ON] = 1; v[OBP_NR_RANGE] = 12; v[OBP_NR_RELEASE] = 100;
  assert(ob_dsp_update(s, v, OBP_COUNT)); ob_dsp_reset(s);
  for (unsigned i = 0; i < count+OB_DSP_LATENCY; i += 256) {
    unsigned n = count+OB_DSP_LATENCY-i;
    ob_dsp_process(s, audio+2*i, n < 256 ? n : 256);
  }
  double early_in = 0, early_out = 0;
  for (unsigned i = 117600; i < 124800; ++i) {
    float y = audio[2*(i+OB_DSP_LATENCY)];
    assert(isfinite(y));
    early_in += input[i]*input[i]; early_out += y*y;
  }
  double early_db = 10*log10(early_out/early_in);
  // Two seconds of silence must not block learning after background arrives.
  assert(early_db < -2 && early_db > -13);

  FFTSetup fft = vDSP_create_fftsetup(9, kFFTRadix2); assert(fft);
  float real[256], imag[256], window[512];
  double energy[2][257] = {{0}}, squared[2][257] = {{0}};
  for (unsigned i = 0; i < fft_size; ++i) window[i] = .5f-.5f*cosf(2*M_PI*i/fft_size);
  unsigned frames = 0;
  for (unsigned i = 5*48000; i+fft_size <= count; i += 256) {
    ++frames;
    for (unsigned source = 0; source < 2; ++source) {
      for (unsigned j = 0; j < 256; ++j) {
        real[j] = (source ? audio[2*(i+2*j+OB_DSP_LATENCY)] : input[i+2*j])*window[2*j];
        imag[j] = (source ? audio[2*(i+2*j+1+OB_DSP_LATENCY)] : input[i+2*j+1])*window[2*j+1];
      }
      DSPSplitComplex z = {real, imag};
      vDSP_fft_zrip(fft, &z, 1, 9, FFT_FORWARD);
      for (unsigned k = 2; k < bins/2; ++k) {
        double power = (double)real[k]*real[k] + (double)imag[k]*imag[k];
        energy[source][k] += power; squared[source][k] += power*power;
      }
    }
  }
  double concentration[2] = {0};
  for (unsigned source = 0; source < 2; ++source)
    for (unsigned k = 2; k < bins/2; ++k)
      concentration[source] += frames*squared[source][k]/(energy[source][k]*energy[source][k]);
  double ratio = concentration[1]/concentration[0];
  printf("NR after silent lead-in: early background=%.2f dB, spectral concentration ratio=%.3f\n",
         early_db, ratio);
  // Guard against sparse, intermittently reopened residual-noise bins. This
  // statistical check does not establish subjective speech quality.
  assert(ratio < 1.25);
  vDSP_destroy_fftsetup(fft);
  ob_dsp_destroy(s); free(input); free(audio);
}
static void low_background_and_voice(void) {
  const unsigned count = 8*48000;
  float *input = calloc(count, sizeof(float));
  float *voice = calloc(count, sizeof(float));
  float *audio = calloc(2*(count+OB_DSP_LATENCY), sizeof(float));
  assert(input && voice && audio);
  unsigned seed = 602;
  float low1 = 0, low2 = 0;
  for (unsigned i = 48000; i < count; ++i) {
    // Rumble below the first nonzero FFT bin, followed by a low voiced phrase.
    low1 = .99f*low1 + .01f*uniform(&seed);
    low2 = .99f*low2 + .01f*low1;
    if (i >= 3*48000 && i < 4*48000) {
      double phase = 2*M_PI*110*i/48000;
      voice[i] = .015f*(sinf(phase) + .5f*sinf(2*phase) + .25f*sinf(3*phase));
    }
    input[i] = .12f*low2 + voice[i];
    audio[2*i] = audio[2*i+1] = input[i];
  }
  OBDSP *s = ob_dsp_create(); assert(s);
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
  v[OBP_NR_ON] = 1; v[OBP_NR_RANGE] = 12; v[OBP_NR_RELEASE] = 100;
  assert(ob_dsp_update(s, v, OBP_COUNT)); ob_dsp_reset(s);
  for (unsigned i = 0; i < count+OB_DSP_LATENCY; i += 256) {
    unsigned remaining = count+OB_DSP_LATENCY-i;
    ob_dsp_process(s, audio+2*i, remaining < 256 ? remaining : 256);
  }
  double in = 0, out = 0, projection = 0, reference = 0;
  for (unsigned i = 0; i < count; ++i) {
    float y = audio[2*(i+OB_DSP_LATENCY)];
    assert(isfinite(y) && fabsf(y) < 1);
    if (i >= 5*48000 && i < 7*48000) {
      in += input[i]*input[i]; out += y*y;
    }
    if (i >= 3*48000 && i < 4*48000) {
      projection += y*voice[i]; reference += voice[i]*voice[i];
    }
  }
  double reduction = 10*log10(out/in);
  double voice_db = 20*log10(fabs(projection/reference));
  printf("NR low-frequency background after voice=%.2f dB, 110 Hz voiced projection=%.2f dB\n",
         reduction, voice_db);
  // A noise-dominated lowest bin must recover after speech without sacrificing
  // the fundamental and harmonics of the preceding low-pitched voice.
  assert(reduction < -6 && reduction > -13);
  assert(voice_db > -2 && voice_db < 1);
  ob_dsp_destroy(s); free(input); free(voice); free(audio);
}
int main(void) {
  noise_and_onset(6, 1, 100);
  noise_and_onset(6, 1, 1000);
  noise_and_onset(0, 0, 0);
  noise_and_onset(40, 5, 1000);
  delayed_background();
  low_background_and_voice();
  puts("PASS colored-noise learning, voiced onset, release and linked stereo");
}
