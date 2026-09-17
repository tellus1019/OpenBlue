#include "OBSignal.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CAPACITY 16384u
#define TAPS 32u
#define PHASES 256u
#define TARGET 1024u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "Audio requires lock-free counters");

struct OBSignal {
  float samples[CAPACITY][2];
  float coefficients[PHASES][TAPS];
  _Atomic uint64_t written, released;
  _Atomic uint64_t underruns, overruns, clipped, frames;
  _Atomic uint32_t input_peak_bits, output_peak_bits, fill;
  OBDSP *dsp;
  float parameters[OBP_COUNT];
  double position;
  float input_meter, output_meter;
  bool primed;
};

static uint32_t bits(float f) {
  uint32_t u;
  memcpy(&u, &f, 4);
  return u;
}
static float value(uint32_t u) {
  float f;
  memcpy(&f, &u, 4);
  return f;
}

OBSignal *ob_signal_create(void) {
  OBSignal *s = calloc(1, sizeof(*s));
  if (!s)
    return NULL;
  s->dsp = ob_dsp_create();
  if (!s->dsp) { free(s); return NULL; }
  for (unsigned i = 0; i < OBP_COUNT; ++i)
    s->parameters[i] = ob_parameter_info(i)->initial;
  for (unsigned p = 0; p < PHASES; ++p) {
    double total = 0;
    for (unsigned t = 0; t < TAPS; ++t) {
      double x = (double)t - 15.0 - (double)p / PHASES;
      double sinc = fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
      double window = 0.5 + 0.5 * cos(M_PI * x / 16.0);
      s->coefficients[p][t] = (float)(sinc * window);
      total += s->coefficients[p][t];
    }
    for (unsigned t = 0; t < TAPS; ++t)
      s->coefficients[p][t] /= total;
  }
  ob_signal_reset(s);
  return s;
}
void ob_signal_destroy(OBSignal *s) {
  if (!s) return;
  ob_dsp_destroy(s->dsp);
  free(s);
}
void ob_signal_reset(OBSignal *s) {
  atomic_store(&s->written, 0);
  atomic_store(&s->released, 0);
  atomic_store(&s->underruns, 0);
  atomic_store(&s->overruns, 0);
  atomic_store(&s->clipped, 0);
  atomic_store(&s->frames, 0);
  atomic_store(&s->input_peak_bits, 0);
  atomic_store(&s->output_peak_bits, 0);
  atomic_store(&s->fill, 0);
  ob_dsp_reset(s->dsp);
  s->position = 15;
  s->input_meter = s->output_meter = 0;
  s->primed = false;
}
void ob_signal_gain(OBSignal *s, float db, bool bypass) {
  if (!isfinite(db) || db < -24 || db > 12)
    return;
  s->parameters[OBP_INPUT_GAIN] = db;
  s->parameters[OBP_BYPASS] = bypass ? 1 : 0;
  ob_dsp_update(s->dsp, s->parameters, OBP_COUNT);
}
bool ob_signal_parameters(OBSignal *s, const float *v, uint32_t n) {
  if (!ob_dsp_update(s->dsp, v, n)) return false;
  memcpy(s->parameters, v, sizeof(s->parameters));
  return true;
}
bool ob_signal_push(OBSignal *s, const float *in, uint32_t n) {
  uint64_t w = atomic_load_explicit(&s->written, memory_order_relaxed);
  uint64_t r = atomic_load_explicit(&s->released, memory_order_acquire);
  if (n > CAPACITY || w - r + n > CAPACITY) {
    atomic_fetch_add_explicit(&s->overruns, 1, memory_order_relaxed);
    return false;
  }
  for (uint32_t i = 0; i < n; ++i) {
    s->samples[(w + i) % CAPACITY][0] = isfinite(in[2 * i]) ? in[2 * i] : 0;
    s->samples[(w + i) % CAPACITY][1] =
        isfinite(in[2 * i + 1]) ? in[2 * i + 1] : 0;
  }
  atomic_store_explicit(&s->written, w + n, memory_order_release);
  return true;
}
static void publish_meters(OBSignal *s, float input, float output, uint32_t n) {
  // Display-only peak envelope: immediate attack, 200 dB/second release at
  // the fixed 48 kHz rate. Every rendered block contributes, including those
  // between UI reads. This never changes the audio samples or buffers.
  float release = powf(10.0f, -200.0f * (float)n / (20.0f * 48000.0f));
  s->input_meter = fmaxf(input, s->input_meter * release);
  s->output_meter = fmaxf(output, s->output_meter * release);
  if (s->input_meter < 0.000001f) s->input_meter = 0;
  if (s->output_meter < 0.000001f) s->output_meter = 0;
  atomic_store_explicit(&s->input_peak_bits, bits(s->input_meter), memory_order_relaxed);
  atomic_store_explicit(&s->output_peak_bits, bits(s->output_meter), memory_order_relaxed);
}
void ob_signal_render(OBSignal *s, float *out, uint32_t n) {
  memset(out, 0, n * 2 * sizeof(float));
  uint64_t w = atomic_load_explicit(&s->written, memory_order_acquire);
  if (!s->primed) {
    uint64_t r = atomic_load_explicit(&s->released, memory_order_relaxed);
    if (w - r < TARGET + n + TAPS) {
      publish_meters(s, 0, 0, n);
      return;
    }
    s->position = (double)w - TARGET - n;
    s->primed = true;
  }
  // Occupancy feedback corrects independent USB and virtual-device clocks.
  // Use block-midpoint occupancy so buffer size does not change the target.
  double error = (double)w - s->position - (double)n / 2 - TARGET;
  double ratio = 1.0 + fmax(-0.005, fmin(0.005, error * 0.000002));
  if (s->position + n * ratio + 17 >= w) {
    atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
    s->primed = false;
    ob_dsp_discontinuity(s->dsp);
    atomic_store_explicit(&s->released, w > TAPS ? w - TAPS : 0,
                          memory_order_release);
    publish_meters(s, 0, 0, n);
    return;
  }
  float in_peak = 0, out_peak = 0;
  uint64_t clipped = 0;
  for (uint32_t i = 0; i < n; ++i) {
    uint64_t center = (uint64_t)s->position;
    unsigned phase = (unsigned)((s->position - center) * PHASES);
    for (unsigned ch = 0; ch < 2; ++ch) {
      float sample = 0;
      for (unsigned t = 0; t < TAPS; ++t)
        sample += s->samples[(center - 15 + t) % CAPACITY][ch] *
                  s->coefficients[phase][t];
      in_peak = fmaxf(in_peak, fabsf(sample));
      out[2 * i + ch] = sample;
    }
    s->position += ratio;
  }
  ob_dsp_process(s->dsp, out, n);
  for (uint32_t i = 0; i < n * 2; ++i) {
    if (fabsf(out[i]) > 1) ++clipped;
    out[i] = isfinite(out[i]) ? fmaxf(-1, fminf(1, out[i])) : 0;
    out_peak = fmaxf(out_peak, fabsf(out[i]));
  }
  atomic_store_explicit(&s->released, (uint64_t)s->position - 15,
                        memory_order_release);
  publish_meters(s, in_peak, out_peak, n);
  atomic_store_explicit(&s->fill, (uint32_t)(w - (uint64_t)s->position),
                        memory_order_relaxed);
  atomic_fetch_add_explicit(&s->clipped, clipped, memory_order_relaxed);
  atomic_fetch_add_explicit(&s->frames, n, memory_order_relaxed);
}
OBSignalStats ob_signal_stats(OBSignal *s) {
  return (OBSignalStats){value(atomic_load(&s->input_peak_bits)),
                         value(atomic_load(&s->output_peak_bits)),
                         atomic_load(&s->underruns),
                         atomic_load(&s->overruns),
                         atomic_load(&s->clipped),
                         atomic_load(&s->frames),
                         atomic_load(&s->fill),
                         ob_dsp_stats(s->dsp)};
}
