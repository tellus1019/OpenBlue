#ifndef OB_NOISE_REDUCTION_INTERNAL_H
#define OB_NOISE_REDUCTION_INTERNAL_H
#include <float.h>

#define NR_BINS (FFT_N / 2 + 1)
#define NR_WINDOWS 4u
#define NR_WINDOW_HOPS 48u

typedef struct {
  float smooth[NR_BINS], noise[NR_BINS];
  float minimum[NR_WINDOWS][NR_BINS];
  float previous_clean[NR_BINS], speech[NR_BINS];
  float speech_mean[NR_BINS], bootstrap_weight[NR_BINS];
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
      s->minimum[w][k] = FLT_MAX;
}

// Minima-controlled candidates bootstrap the noise estimate before suppression.
// Fixed-prior speech presence then tracks noise independently of the output gain.
static void nr_estimate(NoiseEstimator *s, float bias, float sensitivity, float floor) {
  // Digital silence carries no background statistics. Inserting zero minima
  // prevents later background from being learned until every window expires.
  float energy = 0;
  for (unsigned k = 0; k < NR_BINS; ++k) energy += s->power[k];
  if (energy <= 1e-20f) {
    for (unsigned k = 0; k < NR_BINS; ++k)
      s->speech[k] = s->target[k] = 1;
    return;
  }
  unsigned window = (s->frames / NR_WINDOW_HOPS) % NR_WINDOWS;
  if (s->frames % NR_WINDOW_HOPS == 0) {
    for (unsigned k = 0; k < NR_BINS; ++k)
      s->minimum[window][k] = FLT_MAX;
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
    // Fixed-prior SPP separates learning from suppression. Bias and Sensitivity
    // must not change the learned background. Gerkmann/Hendriks (2012), 18/22.
    float learned = fmaxf(s->noise[k], 1e-20f);
    float ratio = fminf(s->power[k]/learned, 1e6f);
    // The packed endpoints are real Gaussian variables, not complex bins.
    float dimensions = k == 0 || k == NR_BINS-1 ? .5f : 1;
    // Equal priors with xi = 10^(15/10): log(1+xi) and xi/(1+xi).
    float log_odds = dimensions*(3.4850107f - .9693466f*ratio);
    float probability = 1/(1+expf(nr_clamp(log_odds, -80, 80)));
    // Time constants at 16 ms hops: .9^(1/3) and 1-.8^(1/3).
    s->speech_mean[k] = .9654894f*s->speech_mean[k] + .0345106f*probability;
    if (s->speech_mean[k] > .99f) probability = fminf(probability, .99f);
    if (s->frames < NR_WINDOW_HOPS || s->bootstrap_weight[k] == 0) {
      if (eligible[k]) {
        float old_weight = .95f*s->bootstrap_weight[k];
        s->bootstrap_weight[k] = old_weight + .05f;
        s->noise[k] = (old_weight*s->noise[k] + .05f*s->power[k]) /
                      s->bootstrap_weight[k];
      }
    } else {
      s->noise[k] += .0716822f*(1-probability)*(s->power[k]-s->noise[k]);
    }
    s->speech[k] = probability;
  }
  for (unsigned k = 0; k < NR_BINS; ++k) {
    float noise = fmaxf(s->noise[k]*bias, 1e-20f);
    float averaged_noise = .25f*s->noise[nr_bin((int)k-1)] + .5f*s->noise[k]
                         + .25f*s->noise[nr_bin((int)k+1)];
    averaged_noise = fmaxf(averaged_noise*bias, 1e-20f);
    // Match the frequency support of the numerator and denominator; adjacent
    // low-frequency energy must not be interpreted as clean speech in this bin.
    float posterior = fminf(s->power[k]/noise, 1e6f);
    float averaged_posterior = fminf(s->smooth[k]/averaged_noise, 1e6f);
    float instantaneous = fmaxf(averaged_posterior-1, 0);
    float prior = .96f*s->previous_clean[k]/noise + .04f*instantaneous;
    float probability = s->speech[k];
    float gain = prior/(prior+1);
    // Sensitivity changes suppression where speech is uncertain; highly likely
    // speech retains the decision-directed Wiener estimate.
    gain *= probability + (1-probability)/sqrtf(sensitivity);
    // A sudden increase above the learned background must not lose its onset.
    float onset = fmaxf(fminf(posterior, averaged_posterior)-1, 0);
    gain = fmaxf(gain, probability*probability*onset/(onset+1));
    gain = nr_clamp(gain, floor, 1);
    float confidence = nr_clamp(((float)s->frames-NR_WINDOW_HOPS)/NR_WINDOW_HOPS, 0, 1);
    s->target[k] = 1 + (gain-1)*confidence;
  }
  ++s->frames;
}
#endif
