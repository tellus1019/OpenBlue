// A full complex, double-precision transform provides the reference for real FFT packing.
#include "../Sources/AudioCore/OBDSP.c"
#include <assert.h>
#include <stdio.h>

static void compare_spectrum(float range) {
  OBDSP *s = ob_dsp_create();
  assert(s);
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
  v[OBP_NR_BIAS] = 3;
  v[OBP_NR_RANGE] = range;
  Prepared p = prepare(v, 40);
  FFTSetupD fft = vDSP_create_fftsetupD(9, kFFTRadix2);
  assert(fft);
  double real[2][FFT_N], imag[2][FFT_N];
  double gain[FFT_N/2+1];
  double overlap[2][FFT_N*2] = {{0}};
  for (unsigned k = 0; k <= FFT_N/2; ++k) gain[k] = 1;
  uint32_t seed = 42;
  double maximum_error = 0;
  for (unsigned frame = 0; frame < 240; ++frame) {
    // Include independent DC, Nyquist, tones and noise on both channels.
    for (unsigned i = 0; i < HOP; ++i) {
      unsigned sample = frame*HOP+i;
      seed = seed*1664525u+1013904223u;
      float noise = .0003f*((seed>>8)/8388608.0f-1);
      float sign = sample%2 ? -1 : 1;
      s->input[0][sample%FFT_N] = .013f + .021f*sign + noise + .002f*sinf(sample*.073f);
      s->input[1][sample%FFT_N] = -.007f + .001f*sign - noise + .09f*cosf(sample*.19f);
    }
    s->clock = (frame+1)*HOP-1;
    for (unsigned ch = 0; ch < 2; ++ch) {
      for (unsigned i = 0; i < FFT_N; ++i) {
        real[ch][i] = (double)s->input[ch][(s->clock+1+i)%FFT_N]*s->window[i];
        imag[ch][i] = 0;
      }
      DSPDoubleSplitComplex z = {real[ch], imag[ch]};
      vDSP_fft_zipD(fft, &z, 1, 9, FFT_FORWARD);
    }
    // Isolate transform accuracy from estimator behavior: apply the real path's
    // mask to an independently transformed double-precision spectrum.
    spectral_frame(s, &p);
    for (unsigned k = 0; k <= FFT_N/2; ++k) {
      gain[k] = s->spectral_gain[k];
      for (unsigned ch = 0; ch < 2; ++ch) {
        real[ch][k] *= gain[k]; imag[ch][k] *= gain[k];
        if (k && k < FFT_N/2) {
          real[ch][FFT_N-k] *= gain[k]; imag[ch][FFT_N-k] *= gain[k];
        }
      }
    }
    for (unsigned ch = 0; ch < 2; ++ch) {
      DSPDoubleSplitComplex z = {real[ch], imag[ch]};
      vDSP_fft_zipD(fft, &z, 1, 9, FFT_INVERSE);
      for (unsigned i = 0; i < FFT_N; ++i)
        overlap[ch][(s->clock+1+i)%(FFT_N*2)] += real[ch][i]*s->window[i]/FFT_N;
    }

    for (unsigned ch = 0; ch < 2; ++ch) {
      for (unsigned i = 0; i < FFT_N*2; ++i) {
        double error = fabs(s->overlap[ch][i]-overlap[ch][i]);
        maximum_error = fmax(maximum_error, error);
        assert(error < 1e-6);
      }
      // Consume output in the same hop cadence as the stream.
      for (unsigned i = 0; i < HOP; ++i) {
        unsigned index = (unsigned)((s->clock+1+i)%(FFT_N*2));
        s->overlap[ch][index] = 0;
        overlap[ch][index] = 0;
      }
    }
  }
  printf("PASS real FFT, range=%.0f dB, max error against complex double reference=%.9g\n",
         range, maximum_error);
  vDSP_destroy_fftsetupD(fft);
  ob_dsp_destroy(s);
}

int main(void) {
  compare_spectrum(0);
  compare_spectrum(24);
}
