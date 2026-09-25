#ifndef OB_NOISE_REDUCTION_INTERNAL_H
#define OB_NOISE_REDUCTION_INTERNAL_H
#include <float.h>

#define NR_BINS (FFT_N / 2 + 1)
#define NR_WINDOWS 4u
#define NR_WINDOW_HOPS 48u

typedef struct {
  float smooth[NR_BINS], quiet[NR_BINS], noise[NR_BINS];
  float minimum[NR_WINDOWS][NR_BINS], quiet_minimum[NR_WINDOWS][NR_BINS];
  float previous_clean[NR_BINS], speech[NR_BINS];
  float power[NR_BINS], target[NR_BINS];
  unsigned frames;
} NoiseEstimator;

static float nr_clamp(float x, float low, float high) {
  return fminf(high, fmaxf(low, x));
}
static unsigned nr_bin(int k) {
  return k < 0 ? 0 : k >= (int)NR_BINS ? NR_BINS-1 : (unsigned)k;
}
static void nr_reset(NoiseEstimator *s) {
  memset(s, 0, sizeof(*s));
  for (unsigned w = 0; w < NR_WINDOWS; ++w)
    for (unsigned k = 0; k < NR_BINS; ++k)
      s->minimum[w][k] = s->quiet_minimum[w][k] = FLT_MAX;
}

// Two-pass minima-controlled averaging excludes likely speech from the second
// smoother. Noise statistics accumulate before suppression is allowed; a first
// frame is never installed as a trusted noise spectrum.
static void nr_estimate(NoiseEstimator *s, float bias, float sensitivity, float floor) {
  unsigned window = (s->frames / NR_WINDOW_HOPS) % NR_WINDOWS;
  if (s->frames % NR_WINDOW_HOPS == 0) {
    for (unsigned k = 0; k < NR_BINS; ++k)
      s->minimum[window][k] = s->quiet_minimum[window][k] = FLT_MAX;
  }
  float eligible[NR_BINS], minima[NR_BINS];
  for (unsigned k = 0; k < NR_BINS; ++k) {
    float smoothed = .25f*s->power[nr_bin((int)k-1)] + .5f*s->power[k]
                   + .25f*s->power[nr_bin((int)k+1)];
    s->smooth[k] = s->frames ? .8f*s->smooth[k] + .2f*smoothed : smoothed;
    s->minimum[window][k] = fminf(s->minimum[window][k], s->smooth[k]);
    float minimum = FLT_MAX;
    for (unsigned w = 0; w < NR_WINDOWS; ++w) minimum = fminf(minimum, s->minimum[w][k]);
    minima[k] = fmaxf(1.66f*minimum, 1e-20f);
  }
  bool tonal[NR_BINS];
  for (unsigned k = 0; k < NR_BINS; ++k) {
    // Spectral prominence protects a voiced component even when capture starts
    // during continuous speech, before temporal minima become informative.
    float surrounding = .25f*(s->smooth[nr_bin((int)k-3)] + s->smooth[nr_bin((int)k-2)]
                           + s->smooth[nr_bin((int)k+2)] + s->smooth[nr_bin((int)k+3)]);
    tonal[k] = s->smooth[k] > 6*fmaxf(surrounding, 1e-20f);
  }
  for (unsigned k = 0; k < NR_BINS; ++k) {
    bool protected = false;
    // The analysis window distributes a component across neighboring bins.
    for (int offset = -2; offset <= 2; ++offset)
      protected |= tonal[nr_bin((int)k+offset)];
    eligible[k] = !protected && s->smooth[k] < 3*minima[k] && s->power[k] < 4.6f*minima[k];
  }
  for (unsigned k = 0; k < NR_BINS; ++k) {
    float total = 0, weight = 0;
    for (int offset = -1; offset <= 1; ++offset) {
      unsigned j = nr_bin((int)k+offset);
      float w = (offset ? .25f : .5f)*eligible[j];
      total += w*s->power[j]; weight += w;
    }
    if (eligible[k] && weight > 0) {
      float quiet = total/weight;
      s->quiet[k] = s->quiet[k] > 0 ? .8f*s->quiet[k] + .2f*quiet : quiet;
      s->quiet_minimum[window][k] = fminf(s->quiet_minimum[window][k], s->quiet[k]);
    }
    float minimum = FLT_MAX;
    for (unsigned w = 0; w < NR_WINDOWS; ++w) minimum = fminf(minimum, s->quiet_minimum[w][k]);
    bool known = minimum != FLT_MAX && minimum > 1e-20f;
    float base = known ? fmaxf(1.66f*minimum, 1e-20f) : 1e-20f;
    float gamma_min = s->power[k]/base, zeta = s->quiet[k]/base;
    float absence = eligible[k] && known ?
        nr_clamp((4.6f-gamma_min)/3.6f, 0, 1)*nr_clamp((1.67f-zeta)/.67f, 0, 1) : 0;
    float noise = fmaxf(s->noise[k]*bias, 1e-20f);
    float posterior = fminf(s->power[k]/noise, 1e6f);
    float instantaneous = fmaxf(posterior-1, 0);
    float prior = .96f*s->previous_clean[k]/noise + .04f*instantaneous;
    float likelihood = prior/(1+prior)*posterior;
    float probability = absence >= 1 ? 0 :
        1/(1 + absence/fmaxf(1-absence, 1e-6f)*(1+prior)*expf(-fminf(likelihood, 80)));
    // Bootstrap only from the second-pass noise candidates. Once established,
    // speech presence continuously slows, rather than globally stops, updates.
    float update = s->frames < NR_WINDOW_HOPS ? .05f*eligible[k] : .05f*(1-probability);
    s->noise[k] += update*(s->power[k]-s->noise[k]);
    s->speech[k] = probability;
    float gain = prior/(prior+1);
    // Sensitivity changes suppression where speech is uncertain; highly likely
    // speech retains the decision-directed Wiener estimate.
    gain *= probability + (1-probability)/sqrtf(sensitivity);
    // A sudden increase above the learned background must not lose its onset.
    if (probability > .8f && instantaneous > 3)
      gain = fmaxf(gain, instantaneous/(instantaneous+1));
    gain = nr_clamp(gain, floor, 1);
    float confidence = nr_clamp(((float)s->frames-NR_WINDOW_HOPS)/NR_WINDOW_HOPS, 0, 1);
    s->target[k] = 1 + (gain-1)*confidence;
  }
  ++s->frames;
}
#endif
