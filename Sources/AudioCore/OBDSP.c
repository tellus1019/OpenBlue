#include "OBDSP.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef OB_DSP_PROFILE
#include <mach/mach_time.h>
#define PROFILE_START uint64_t profile_mark = mach_absolute_time()
#define PROFILE_STAGE(group) do { \
  uint64_t now = mach_absolute_time(); \
  s->profile_ticks[group] += now - profile_mark; profile_mark = now; \
} while (0)
#else
#define PROFILE_START ((void)0)
#define PROFILE_STAGE(group) ((void)0)
#endif

#define RATE 48000.0f
#define FFT_N 512u
#define HOP 256u
#define LOOK 480u
#define LIMIT_RING (LOOK + 1)
#include "OBNoiseReduction.h"
#define DIRTY 4u
#define COEFF_BLEND (1.0 / 480.0)
#define CONTROL_BLEND (1.0f / 240.0f)
#define FILTER_PREROLL 2400u
#define PROCESSOR_MASK ((1u << OB_DSP_GROUPS) - 2u)

static const OBParameterInfo parameters[] = {
#define OB_PARAM(id, key, label, unit, group, lo, hi, initial, step, kind) \
  {key, label, unit, group, lo, hi, initial, step, kind},
#include "OBParameters.def"
#undef OB_PARAM
};
const OBParameterInfo *ob_parameter_info(uint32_t i) {
  return i < OBP_COUNT ? &parameters[i] : NULL;
}
uint32_t ob_parameter_count(void) { return OBP_COUNT; }
bool ob_parameters_valid(const float *v, uint32_t n) {
  if (!v || n != OBP_COUNT) return false;
  for (unsigned i = 0; i < n; ++i) {
    if (!isfinite(v[i]) || v[i] < parameters[i].minimum ||
        v[i] > parameters[i].maximum) return false;
    if (parameters[i].kind == OB_PARAMETER_BOOLEAN &&
        v[i] != 0 && v[i] != 1) return false;
  }
  return true;
}
typedef struct { double b0, b1, b2, a1, a2; } Coeff;
typedef struct {
  Coeff c;
  double x1[2], x2[2], y1[2], y2[2];
  bool smoothing;
} Filter;
typedef struct {
  double ic1[2], ic2[2], g, inverse_q;
} DynamicBand;
typedef struct {
  float v[OBP_COUNT];
  // HPF, three EQ bands and two normalized band detectors.
  Coeff filters[6];
  double band_g[2], band_inverse_q[2];
  float gain_in, gain_out, makeup, pre_gain, limit_boost, nr_bias, nr_sensitivity, nr_min, nr_release;
  float gate_attack, gate_release, gate_open, gate_close;
  float esser_attack, esser_release, popper_attack, popper_release;
  float comp_attack, comp_release, ceiling, limit_release;
  float comp_slope, advanced_floor;
  unsigned gate_hold, limit_attack;
} Prepared;
struct OBDSP {
#ifdef OB_DSP_PROFILE
  uint64_t profile_ticks[OB_DSP_GROUPS];
#endif
  Prepared slots[3];
  unsigned back, front;
  _Atomic unsigned middle;
  FFTSetup fft;
  Filter filters[6];
  DynamicBand bands[2];
  float gain_in, gain_out, makeup, pre_gain, limit_boost, mix[OB_DSP_GROUPS], bypass;
  unsigned limit_attack;
  bool rebuild_peaks;
  bool active[OB_DSP_GROUPS];
  unsigned preroll[OB_DSP_GROUPS];
  float input[2][FFT_N], overlap[2][FFT_N * 2], window[FFT_N];
  float real[2][FFT_N / 2], imag[2][FFT_N / 2], spectral_gain[FFT_N / 2 + 1];
  NoiseEstimator noise;
  float dry[2][OB_ADVANCED_DSP_LATENCY];
  OBAdvancedNR neural;
  float neural_input[OB_ADVANCED_HOP * 2], neural_output[OB_ADVANCED_HOP * 2];
  float neural_dry[OB_ADVANCED_HOP * 2], neural_history[OB_ADVANCED_NR_LATENCY][2];
  float advanced_range; // Serialized control writer only.
  float neural_floor;
  bool neural_running;
  uint64_t clock;
  float gate_detector, gate_db, comp_detector, comp_db;
  float esser_detector, esser_db, popper_detector, popper_db;
  unsigned hold;
  bool gate_open;
  float limit_samples[LIMIT_RING][2], limit_gain, ceiling;
  float peak_queue[LIMIT_RING + 1];
  uint64_t peak_time[LIMIT_RING + 1], queue_head, queue_tail;
  _Atomic uint32_t reduction_bits[OB_DSP_GROUPS];
  _Atomic uint64_t invalid_samples;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
               "DSP handoff requires lock-free atomics");
static float amplitude(float db) { return powf(10, db / 20); }
static float dbfs(float x) { return 20 * log10f(fmaxf(x, 1e-12f)); }
static float response(float ms) { return ms == 0 ? 0 : expf(-1 / (ms * 0.001f * RATE)); }
static float approach(float current, float target, float rate) {
  return target + rate * (current - target);
}
static float blend(float current, float target) {
  float next = current + (target-current)*CONTROL_BLEND;
  return fabsf(next-target) < 1e-5f ? target : next;
}
static uint32_t bits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float from_bits(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static Coeff coefficients(float hz, float q, float db, int type) {
  double w = 2 * M_PI * hz / RATE, co = cos(w), alpha = sin(w) / (2 * q);
  double a = pow(10, db / 40), a0;
  Coeff c;
  if (type == 0) {
    a0 = 1 + alpha;
    c = (Coeff){(1+co)/2, -(1+co), (1+co)/2, -2*co, 1-alpha};
  } else if (type == 1) {
    a0 = 1 + alpha;
    c = (Coeff){(1-co)/2, 1-co, (1-co)/2, -2*co, 1-alpha};
  } else if (type == 3) {
    a0 = 1 + alpha;
    c = (Coeff){alpha, 0, -alpha, -2*co, 1-alpha};
  } else {
    a0 = 1 + alpha/a;
    c = (Coeff){1+alpha*a, -2*co, 1-alpha*a, -2*co, 1-alpha/a};
  }
  c.b0 /= a0; c.b1 /= a0; c.b2 /= a0; c.a1 /= a0; c.a2 /= a0;
  return c;
}
static Prepared prepare(const float *v, float advanced_range) {
  Prepared p = {0};
  memcpy(p.v, v, sizeof(p.v));
  p.advanced_floor = amplitude(-advanced_range);
  p.filters[0] = coefficients(v[OBP_HPF_HZ], M_SQRT1_2, 0, 0);
  for (unsigned i = 0; i < 3; ++i)
    p.filters[i+1] = coefficients(v[OBP_EQ1_HZ+i*3], v[OBP_EQ1_Q+i*3],
                                   v[OBP_EQ1_DB+i*3], 2);
  p.filters[4] = coefficients(v[OBP_ESSER_HZ], v[OBP_ESSER_Q], 0, 3);
  p.filters[5] = coefficients(v[OBP_POPPER_HZ], v[OBP_POPPER_Q], 0, 3);
  p.band_g[0] = tan(M_PI * v[OBP_ESSER_HZ] / RATE);
  p.band_g[1] = tan(M_PI * v[OBP_POPPER_HZ] / RATE);
  p.band_inverse_q[0] = 1.0 / v[OBP_ESSER_Q];
  p.band_inverse_q[1] = 1.0 / v[OBP_POPPER_Q];
  p.gain_in = amplitude(v[OBP_INPUT_GAIN]);
  p.gain_out = v[OBP_OUTPUT_MUTE] ? 0 : amplitude(v[OBP_OUTPUT_GAIN]);
  p.pre_gain = amplitude(v[OBP_COMP_PREGAIN]);
  p.limit_boost = amplitude(v[OBP_LIMIT_BOOST]);
  p.limit_attack = (unsigned)lroundf(v[OBP_LIMIT_ATTACK]*48);
  p.makeup = amplitude(v[OBP_COMP_MAKEUP]);
  p.nr_bias = powf(10, v[OBP_NR_BIAS]/10);
  p.nr_sensitivity = powf(10, v[OBP_NR_SENSITIVITY]/10);
  p.nr_min = amplitude(-v[OBP_NR_RANGE]);
  p.nr_release = v[OBP_NR_RELEASE] == 0 ? 0 : expf(-(float)HOP / (v[OBP_NR_RELEASE] * .001f * RATE));
  p.gate_attack = response(v[OBP_GATE_ATTACK]);
  p.gate_release = response(v[OBP_GATE_RELEASE]);
  p.gate_open = amplitude(v[OBP_GATE_THRESHOLD]);
  p.gate_close = amplitude(v[OBP_GATE_THRESHOLD]-3);
  p.gate_hold = (unsigned)(v[OBP_GATE_HOLD]*48);
  p.esser_attack = response(v[OBP_ESSER_ATTACK]);
  p.esser_release = response(v[OBP_ESSER_RELEASE]);
  p.popper_attack = response(v[OBP_POPPER_ATTACK]);
  p.popper_release = response(v[OBP_POPPER_RELEASE]);
  p.comp_attack = response(v[OBP_COMP_ATTACK]);
  p.comp_release = response(v[OBP_COMP_RELEASE]);
  p.comp_slope = 1-1/v[OBP_COMP_RATIO];
  p.ceiling = amplitude(v[OBP_LIMIT_CEILING]);
  p.limit_release = response(v[OBP_LIMIT_RELEASE]);
  return p;
}
uint32_t ob_dsp_latency_frames(void) { return OB_DSP_LATENCY; }
OBDSP *ob_dsp_create(void) {
  OBDSP *s = calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->fft = vDSP_create_fftsetup(9, kFFTRadix2);
  if (!s->fft) { free(s); return NULL; }
  // Warm the in-place transform before the first audio callback.
  DSPSplitComplex warm = {s->real[0], s->imag[0]};
  vDSP_fft_zrip(s->fft, &warm, 1, 9, FFT_FORWARD);
  vDSP_fft_zrip(s->fft, &warm, 1, 9, FFT_INVERSE);
  for (unsigned i = 0; i < FFT_N; ++i)
    s->window[i] = sqrtf(.5f - .5f*cosf(2*M_PI*i/FFT_N));
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = parameters[i].initial;
  s->advanced_range = 40;
  s->slots[0] = s->slots[1] = s->slots[2] = prepare(v, s->advanced_range);
  s->front = 0; s->back = 2;
  atomic_init(&s->middle, 1);
  ob_dsp_reset(s);
  return s;
}
void ob_dsp_destroy(OBDSP *s) {
  if (!s) return;
  vDSP_destroy_fftsetup(s->fft);
  free(s);
}
void ob_dsp_discontinuity(OBDSP *s) {
  Prepared *p = &s->slots[s->front];
  memset(s->filters, 0, sizeof(s->filters));
  for (unsigned i = 0; i < 6; ++i) s->filters[i].c = p->filters[i];
  memset(s->bands, 0, sizeof(s->bands));
  for (unsigned i = 0; i < 2; ++i) {
    s->bands[i].g = p->band_g[i]; s->bands[i].inverse_q = p->band_inverse_q[i];
  }
  memset(s->input, 0, sizeof(s->input));
  memset(s->overlap, 0, sizeof(s->overlap));
  nr_reset(&s->noise);
  memset(s->dry, 0, sizeof(s->dry));
  memset(s->neural_history, 0, sizeof(s->neural_history));
  s->neural_running = false;
  s->neural_floor = p->advanced_floor;
  memset(s->limit_samples, 0, sizeof(s->limit_samples));
  memset(s->mix, 0, sizeof(s->mix));
  memset(s->active, 0, sizeof(s->active));
  memset(s->preroll, 0, sizeof(s->preroll));
  s->clock = s->queue_head = s->queue_tail = 0;
  s->gain_in = p->gain_in; s->gain_out = p->gain_out; s->makeup = p->makeup;
  s->pre_gain = p->pre_gain; s->limit_boost = p->limit_boost;
  s->limit_attack = p->limit_attack; s->rebuild_peaks = true;
  s->bypass = p->v[OBP_BYPASS];
  s->gate_detector = s->comp_detector = s->esser_detector = s->popper_detector = 0;
  s->gate_db = s->comp_db = s->esser_db = s->popper_db = 0;
  s->hold = 0; s->gate_open = false; s->limit_gain = 1;
  s->ceiling = p->ceiling;
  for (unsigned i = 0; i <= FFT_N/2; ++i) s->spectral_gain[i] = 1;
  for (unsigned i = 0; i < OB_DSP_GROUPS; ++i) atomic_store(&s->reduction_bits[i], 0);
}
void ob_dsp_reset(OBDSP *s) {
  // No writer or reader may run concurrently with a stopped reset.
  unsigned m = atomic_load(&s->middle);
  if (m & DIRTY) {
    unsigned old = s->front;
    s->front = m & 3;
    atomic_store(&s->middle, old);
  }
  ob_dsp_discontinuity(s);
  atomic_store(&s->invalid_samples, 0);
}
bool ob_dsp_update(OBDSP *s, const float *v, uint32_t n) {
  return ob_dsp_update_advanced(s, v, n, s->advanced_range);
}
bool ob_dsp_update_advanced(OBDSP *s, const float *v, uint32_t n, float range) {
  if (!ob_parameters_valid(v, n) || !isfinite(range) || range < 0 || range > 60)
    return false;
  s->slots[s->back] = prepare(v, range);
  s->advanced_range = range;
  s->back = atomic_exchange_explicit(&s->middle, s->back | DIRTY,
                                     memory_order_acq_rel) & 3;
  return true;
}
static void smooth_coeff(Filter *f, Coeff target) {
  if (!f->smoothing) return;
  Coeff previous = f->c;
#define MOVE(field) f->c.field += (target.field - f->c.field) * COEFF_BLEND
  MOVE(b0); MOVE(b1); MOVE(b2); MOVE(a1); MOVE(a2);
#undef MOVE
  // Stop only when the same arithmetic no longer changes any coefficient.
  f->smoothing = f->c.b0 != previous.b0 || f->c.b1 != previous.b1 ||
                 f->c.b2 != previous.b2 || f->c.a1 != previous.a1 ||
                 f->c.a2 != previous.a2;
}
static float filter(Filter *f, float x, unsigned ch) {
  Coeff c = f->c;
  double y = c.b0*x + c.b1*f->x1[ch] + c.b2*f->x2[ch]
             - c.a1*f->y1[ch] - c.a2*f->y2[ch];
  f->x2[ch] = f->x1[ch]; f->x1[ch] = x;
  f->y2[ch] = f->y1[ch]; f->y1[ch] = fabs(y) < 1e-30 ? 0 : y;
  return (float)y;
}
static void spectral_frame(OBDSP *s, const Prepared *p) {
  for (unsigned ch = 0; ch < 2; ++ch) {
    // Even/odd packing and half-scale input compensate the real FFT's factor of two.
    for (unsigned i = 0; i < FFT_N/2; ++i) {
      s->real[ch][i] = .5f * (s->input[ch][(s->clock+1+2*i)%FFT_N]*s->window[2*i]);
      s->imag[ch][i] = .5f * (s->input[ch][(s->clock+2+2*i)%FFT_N]*s->window[2*i+1]);
    }
    DSPSplitComplex z = {s->real[ch], s->imag[ch]};
    vDSP_fft_zrip(s->fft, &z, 1, 9, FFT_FORWARD);
  }
  for (unsigned k = 0; k <= FFT_N/2; ++k) {
    float power = 0;
    for (unsigned ch = 0; ch < 2; ++ch) {
      // DC and Nyquist are separate real bins packed into element zero.
      float re = k == FFT_N/2 ? s->imag[ch][0] : s->real[ch][k];
      float im = k == 0 || k == FFT_N/2 ? 0 : s->imag[ch][k];
      power = fmaxf(power, re*re + im*im);
    }
    s->noise.power[k] = power;
  }
  nr_estimate(&s->noise, p->nr_bias, p->nr_sensitivity, p->nr_min);
  for (unsigned k = 0; k <= FFT_N/2; ++k) {
    unsigned left = k ? k-1 : k, right = k < FFT_N/2 ? k+1 : k;
    float target = .25f*s->noise.target[left] + .5f*s->noise.target[k]
                   + .25f*s->noise.target[right];
    float presence = s->noise.speech[k]*s->noise.speech[k];
    target += presence*fmaxf(0, s->noise.target[k]-target);
    float recovery = p->nr_release + presence*(fminf(.2f, p->nr_release)-p->nr_release);
    float a = target < s->spectral_gain[k] ? .3f : recovery;
    s->spectral_gain[k] = approach(s->spectral_gain[k], target, a);
    s->noise.previous_clean[k] = s->spectral_gain[k]*s->spectral_gain[k]*s->noise.power[k];
    for (unsigned ch = 0; ch < 2; ++ch) {
      if (k == FFT_N/2) {
        s->imag[ch][0] *= s->spectral_gain[k];
      } else {
        s->real[ch][k] *= s->spectral_gain[k];
        if (k) s->imag[ch][k] *= s->spectral_gain[k];
      }
    }
  }
  for (unsigned ch = 0; ch < 2; ++ch) {
    DSPSplitComplex z = {s->real[ch], s->imag[ch]};
    vDSP_fft_zrip(s->fft, &z, 1, 9, FFT_INVERSE);
    for (unsigned i = 0; i < FFT_N/2; ++i) {
      s->overlap[ch][(s->clock+1+2*i)%(FFT_N*2)] +=
          s->real[ch][i] * s->window[2*i] / FFT_N;
      s->overlap[ch][(s->clock+2+2*i)%(FFT_N*2)] +=
          s->imag[ch][i] * s->window[2*i+1] / FFT_N;
    }
  }
}

static const unsigned filter_group[6] = {1, 4, 4, 4, 5, 6};
static const unsigned enable[OB_DSP_GROUPS] = {
  0, OBP_HPF_ON, OBP_NR_ON, OBP_GATE_ON, OBP_EQ_ON,
  OBP_ESSER_ON, OBP_POPPER_ON, OBP_COMP_ON, OBP_LIMIT_ON
};

static void wake_group(OBDSP *s, const Prepared *p, unsigned group) {
  for (unsigned f = 0; f < 6; ++f) {
    if (filter_group[f] != group) continue;
    memset(&s->filters[f], 0, sizeof(s->filters[f]));
    s->filters[f].c = p->filters[f];
  }
  if (group == 5 || group == 6) {
    unsigned band = group - 5;
    memset(&s->bands[band], 0, sizeof(s->bands[band]));
    s->bands[band].g = p->band_g[band];
    s->bands[band].inverse_q = p->band_inverse_q[band];
  }
  s->preroll[group] = FILTER_PREROLL;
  switch (group) {
    case 2:
      memset(s->overlap, 0, sizeof(s->overlap));
      nr_reset(&s->noise);
      for (unsigned k = 0; k <= FFT_N/2; ++k) s->spectral_gain[k] = 1;
      // Keep dry input history; wait for complete overlapping output windows.
      s->preroll[group] = s->neural.process ? OB_ADVANCED_NR_LATENCY : FFT_N + HOP;
      break;
    case 3:
      s->gate_detector = s->gate_db = 0;
      s->gate_open = false; s->hold = 0;
      break;
    case 5: s->esser_detector = s->esser_db = 0; break;
    case 6: s->popper_detector = s->popper_db = 0; break;
    case 7: s->comp_detector = s->comp_db = 0; break;
    case 8:
      s->queue_head = s->queue_tail = 0;
      s->limit_gain = 1; s->rebuild_peaks = true;
      s->preroll[group] = LIMIT_RING;
      break;
    default: break;
  }
  s->active[group] = true;
}

static void update_group(OBDSP *s, const Prepared *p, unsigned group, bool enabled) {
  if (!s->active[group]) {
    if (!enabled) return;
    wake_group(s, p, group);
  }
  if (!enabled) {
    s->preroll[group] = 0;
    s->mix[group] = blend(s->mix[group], 0);
    if (s->mix[group] == 0) s->active[group] = false;
  } else if (s->preroll[group]) {
    --s->preroll[group];
  } else if (s->mix[group] != 1) {
    s->mix[group] = blend(s->mix[group], 1);
  }
}
static float detector(float previous, float peak) {
  // Peak hold with a 20 ms exponential decay avoids cycle-by-cycle gain chatter.
  return fmaxf(peak, previous * 0.9989588757f);
}
static float band_reduction(float peak, float *envelope, float *reduction,
                            float threshold, float range, float attack, float release,
                            bool audible) {
  *envelope = detector(*envelope, peak);
  float target = fminf(range, fmaxf(0, dbfs(*envelope)-threshold));
  *reduction = approach(*reduction, target, target > *reduction ? attack : release);
  return audible ? amplitude(-*reduction) : 1;
}
// The bell has unity gain outside its band and exactly unity at zero reduction.
// Its TPT integrator state remains meaningful while the damping changes.
static void dynamic_band(DynamicBand *f, float x[2], float gain) {
  double a = sqrt((double)gain), k = f->inverse_q / a;
  double a1 = 1 / (1 + f->g * (f->g + k));
  double a2 = f->g * a1, a3 = f->g * a2;
  double m = k * ((double)gain - 1);
  for (unsigned ch = 0; ch < 2; ++ch) {
    double v3 = x[ch] - f->ic2[ch];
    double v1 = a1*f->ic1[ch] + a2*v3;
    double v2 = f->ic2[ch] + a2*f->ic1[ch] + a3*v3;
    f->ic1[ch] = 2*v1 - f->ic1[ch];
    f->ic2[ch] = 2*v2 - f->ic2[ch];
    x[ch] += m*v1;
  }
}
static void enqueue_peak(OBDSP *s, uint64_t time, unsigned index) {
  float peak = fmaxf(fabsf(s->limit_samples[index][0]), fabsf(s->limit_samples[index][1]));
  while (s->queue_head < s->queue_tail &&
         s->peak_queue[(s->queue_tail-1)%(LIMIT_RING+1)] <= peak) --s->queue_tail;
  s->peak_queue[s->queue_tail%(LIMIT_RING+1)] = peak;
  s->peak_time[s->queue_tail%(LIMIT_RING+1)] = time;
  ++s->queue_tail;
}
// Constant activity at the call site removes suspension branches from the wet path.
static inline __attribute__((always_inline)) void process_block(
    OBDSP *s, float *out, uint32_t n, const Prepared *p, unsigned active_mask,
    bool update_activity, bool update_coefficients, bool advanced) {
  const float *v = p->v;
  const unsigned latency = advanced ? OB_ADVANCED_DSP_LATENCY : OB_DSP_LATENCY;
  const float floor_target = p->advanced_floor;
  float reduction[OB_DSP_GROUPS] = {0};
  float minimum_limit_gain = 1;
  double nr_in_power = 0, nr_out_power = 0;
  uint64_t invalid = 0;
  for (unsigned i = 0; i < n; ++i, ++s->clock) {
    PROFILE_START;
    float x[2], dry[2];
    for (unsigned ch = 0; ch < 2; ++ch) {
      float input = out[2*i+ch];
      if (!isfinite(input)) { input = 0; ++invalid; }
      dry[ch] = s->dry[ch][s->clock%latency];
      s->dry[ch][s->clock%latency] = input;
      x[ch] = input;
    }
    if (!advanced) s->gain_in += (p->gain_in-s->gain_in)*CONTROL_BLEND;
    s->gain_out = blend(s->gain_out, p->gain_out);
    s->pre_gain = blend(s->pre_gain, p->pre_gain);
    s->limit_boost = blend(s->limit_boost, p->limit_boost);
    s->makeup += (p->makeup-s->makeup)*CONTROL_BLEND;
    s->ceiling = blend(s->ceiling, p->ceiling);
    s->bypass = blend(s->bypass, v[OBP_BYPASS]);
    if (update_activity) {
      active_mask = 0;
      for (unsigned g = 1; g < OB_DSP_GROUPS; ++g) {
        if (!(advanced && g == 1))
          update_group(s, p, g, v[enable[g]] != 0 && !(advanced && g == 2 && !s->neural_running));
        if (s->active[g]) active_mask |= 1u << g;
      }
    }
    if (update_coefficients) {
      for (unsigned f = advanced ? 1 : 0; f < 6; ++f)
        if (active_mask & (1u << filter_group[f]))
          smooth_coeff(&s->filters[f], p->filters[f]);
    }
    PROFILE_STAGE(0);
    if (advanced) {
      s->neural_floor = blend(s->neural_floor, floor_target);
      for (unsigned ch = 0; ch < 2; ++ch) {
        float delayed = s->neural_dry[2*i+ch];
        float wet = s->neural_output[2*i+ch];
        x[ch] = delayed + (wet-delayed)*s->mix[2]*(1-s->neural_floor);
        nr_in_power += delayed*delayed; nr_out_power += x[ch]*x[ch];
      }
    } else {
      for (unsigned ch = 0; ch < 2; ++ch) {
        x[ch] *= s->gain_in;
        if (active_mask & (1u << 1))
          x[ch] += (filter(&s->filters[0], x[ch], ch)-x[ch])*s->mix[1];
        PROFILE_STAGE(1);
        float delayed = s->input[ch][s->clock%FFT_N];
        s->input[ch][s->clock%FFT_N] = x[ch];
        x[ch] = delayed;
        if (active_mask & (1u << 2)) {
          float wet = s->overlap[ch][s->clock%(FFT_N*2)];
          s->overlap[ch][s->clock%(FFT_N*2)] = 0;
          x[ch] += (wet-delayed)*s->mix[2];
          nr_in_power += delayed*delayed; nr_out_power += x[ch]*x[ch];
        }
        PROFILE_STAGE(2);
      }
      if ((active_mask & (1u << 2)) && s->clock%HOP == HOP-1) spectral_frame(s, p);
      PROFILE_STAGE(2);
    }
    float peak = fmaxf(fabsf(x[0]), fabsf(x[1]));
    float gate = 1;
    if (active_mask & (1u << 3)) {
      s->gate_detector = detector(s->gate_detector, peak);
      if (s->gate_detector >= p->gate_open) {
        s->gate_open = true; s->hold = p->gate_hold;
      } else if (s->gate_detector < p->gate_close) {
        if (s->hold) --s->hold; else s->gate_open = false;
      }
      float gate_target = s->gate_open ? 0 : v[OBP_GATE_RANGE];
      s->gate_db = approach(s->gate_db, gate_target,
                            gate_target < s->gate_db ? p->gate_attack : p->gate_release);
      gate = s->mix[3] == 0 ? 1 : amplitude(-s->gate_db*s->mix[3]);
      reduction[3] = fmaxf(reduction[3], s->gate_db*s->mix[3]);
    }
    PROFILE_STAGE(3);
    for (unsigned ch = 0; ch < 2; ++ch) {
      x[ch] *= gate;
      PROFILE_STAGE(3);
      if (active_mask & (1u << 4)) {
        float eq = x[ch];
        for (unsigned f = 1; f < 4; ++f) eq = filter(&s->filters[f], eq, ch);
        x[ch] += (eq-x[ch])*s->mix[4];
      }
      PROFILE_STAGE(4);
    }
    for (unsigned stage = 0; stage < 2; ++stage) {
      if (!(active_mask & (1u << (5+stage)))) { PROFILE_STAGE(5+stage); continue; }
      float band[2];
      for (unsigned ch = 0; ch < 2; ++ch)
        band[ch] = filter(&s->filters[4+stage], x[ch], ch);
      float bp = fmaxf(fabsf(band[0]), fabsf(band[1]));
      float gain;
      if (!stage) gain = band_reduction(bp, &s->esser_detector, &s->esser_db,
          v[OBP_ESSER_THRESHOLD], v[OBP_ESSER_RANGE], p->esser_attack, p->esser_release,
          s->mix[5] != 0);
      else gain = band_reduction(bp, &s->popper_detector, &s->popper_db,
          v[OBP_POPPER_THRESHOLD], v[OBP_POPPER_RANGE], p->popper_attack, p->popper_release,
          s->mix[6] != 0);
      DynamicBand *band_filter = &s->bands[stage];
      band_filter->g += (p->band_g[stage]-band_filter->g)*COEFF_BLEND;
      band_filter->inverse_q += (p->band_inverse_q[stage]-band_filter->inverse_q)*COEFF_BLEND;
      float processed[2] = {x[0], x[1]};
      dynamic_band(band_filter, processed, gain);
      for (unsigned ch = 0; ch < 2; ++ch)
        x[ch] += (processed[ch]-x[ch])*s->mix[5+stage];
      reduction[5+stage] = fmaxf(reduction[5+stage],
                                (stage ? s->popper_db : s->esser_db)*s->mix[5+stage]);
      PROFILE_STAGE(5+stage);
    }
    float comp = 1;
    if (active_mask & (1u << 7)) {
      s->comp_detector = detector(s->comp_detector, s->pre_gain*fmaxf(fabsf(x[0]), fabsf(x[1])));
      float excess = dbfs(s->comp_detector)-v[OBP_COMP_THRESHOLD];
      float compression = excess <= -3 ? 0 :
          (excess >= 3 ? excess : (excess+3)*(excess+3)/12);
      float comp_target = compression*p->comp_slope;
      s->comp_db = approach(s->comp_db, comp_target,
                            comp_target > s->comp_db ? p->comp_attack : p->comp_release);
      if (s->mix[7] != 0)
        comp = 1 + (amplitude(-s->comp_db)*s->makeup*s->pre_gain-1)*s->mix[7];
      reduction[7] = fmaxf(reduction[7], s->comp_db*s->mix[7]);
    }
    for (unsigned ch = 0; ch < 2; ++ch) {
      x[ch] *= comp*(1 + (s->limit_boost-1)*s->mix[8]);
      if (!isfinite(x[ch])) { x[ch] = 0; ++invalid; }
      s->limit_samples[s->clock%LIMIT_RING][ch] = x[ch];
    }
    PROFILE_STAGE(7);
    unsigned delayed_index = (unsigned)((s->clock+1)%LIMIT_RING);
    float limit_mix = 1;
    if (active_mask & (1u << 8)) {
      if (s->limit_attack != p->limit_attack) {
        s->limit_attack = p->limit_attack; s->rebuild_peaks = true;
      }
      while (s->queue_head < s->queue_tail &&
             s->peak_time[s->queue_head%(LIMIT_RING+1)] < s->clock) ++s->queue_head;
      if (s->rebuild_peaks) {
        s->queue_head = s->queue_tail = 0;
        for (unsigned offset = 0; offset < s->limit_attack; ++offset)
          enqueue_peak(s, s->clock+offset, (delayed_index+offset)%LIMIT_RING);
        s->rebuild_peaks = false;
      }
      enqueue_peak(s, s->clock+s->limit_attack,
                   (delayed_index+s->limit_attack)%LIMIT_RING);
      float maximum = s->peak_queue[s->queue_head%(LIMIT_RING+1)];
      float limit = fminf(1, s->ceiling/fmaxf(maximum, 1e-20f));
      s->limit_gain = limit < s->limit_gain ?
          (s->limit_attack ? fmaxf(limit, s->limit_gain-(1-limit)/s->limit_attack) : limit) :
          approach(s->limit_gain, limit, p->limit_release);
      // A lower user ceiling can arrive after a sample entered lookahead.
      // Follow its smoothed value on the sample being emitted as well.
      float emitted_peak = fmaxf(fabsf(s->limit_samples[delayed_index][0]),
                                 fabsf(s->limit_samples[delayed_index][1]));
      s->limit_gain = fminf(s->limit_gain, s->ceiling/fmaxf(emitted_peak, 1e-20f));
      // The meter reports the block maximum; steady wet gain needs one dB conversion.
      if (s->mix[8] == 1)
        minimum_limit_gain = fminf(minimum_limit_gain, s->limit_gain);
      else if (s->mix[8] != 0)
        reduction[8] = fmaxf(reduction[8], -dbfs(s->limit_gain)*s->mix[8]);
      limit_mix = 1 + (s->limit_gain-1)*s->mix[8];
    }
    for (unsigned ch = 0; ch < 2; ++ch) {
      float wet = s->limit_samples[delayed_index][ch]*limit_mix;
      out[2*i+ch] = (wet + (dry[ch]-wet)*s->bypass)*s->gain_out;
    }
    PROFILE_STAGE(8);
  }
  if (minimum_limit_gain < 1)
    reduction[8] = fmaxf(reduction[8], -dbfs(minimum_limit_gain));
  reduction[2] = nr_in_power > 1e-20 ? fmaxf(0, 10*log10(nr_in_power/fmax(nr_out_power,1e-20))) : 0;
  for (unsigned g = 0; g < OB_DSP_GROUPS; ++g)
    atomic_store_explicit(&s->reduction_bits[g], bits(reduction[g]*(1-s->bypass)),
                           memory_order_relaxed);
  atomic_fetch_add_explicit(&s->invalid_samples, invalid, memory_order_relaxed);
}
static const Prepared *consume_parameters(OBDSP *s) {
  if (atomic_load_explicit(&s->middle, memory_order_acquire) & DIRTY) {
    s->front = atomic_exchange_explicit(&s->middle, s->front,
                                        memory_order_acq_rel) & 3;
    for (unsigned f = 0; f < 6; ++f) s->filters[f].smoothing = true;
  }
  return &s->slots[s->front];
}
void ob_dsp_process(OBDSP *s, float *out, uint32_t n) {
  const Prepared *p = consume_parameters(s);
  unsigned active_mask = 0;
  bool update_activity = false, update_coefficients = false;
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g) {
    if (s->active[g]) active_mask |= 1u << g;
    bool enabled = p->v[enable[g]] != 0;
    if (s->active[g] != enabled || s->preroll[g] || s->mix[g] != p->v[enable[g]])
      update_activity = true;
  }
  for (unsigned f = 0; f < 6; ++f)
    if ((active_mask & (1u << filter_group[f])) && s->filters[f].smoothing)
      update_coefficients = true;

  // The snapshot stays fixed for this block. Only transitions need sample updates.
  // Waking filters copy its coefficients directly, so they need no coefficient ramp.
  if (active_mask == PROCESSOR_MASK && !update_activity && !update_coefficients)
    process_block(s, out, n, p, PROCESSOR_MASK, false, false, false);
  else
    process_block(s, out, n, p, active_mask, update_activity, update_coefficients, false);
}
bool ob_dsp_attach_advanced(OBDSP *s, OBAdvancedNR processor) {
  if (!s || !processor.process || !processor.reset) return false;
  s->neural = processor;
  ob_dsp_reset(s);
  return true;
}
bool ob_dsp_process_advanced(OBDSP *s, float *out) {
  if (!s->neural.process) return false;
  const Prepared *p = consume_parameters(s);
  bool requested = p->v[OBP_NR_ON] != 0 && p->v[OBP_BYPASS] == 0;
  bool running = requested || (s->neural_running && s->mix[2] != 0 && s->bypass != 1);
  if (running && !s->neural_running) {
    if (!s->neural.reset(s->neural.context)) return false;
    s->active[2] = false; s->mix[2] = 0;
  }
  s->neural_running = running;
  // Preprocess a complete hop before prediction, avoiding an extra hop of delay.
  for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i) {
    s->gain_in += (p->gain_in-s->gain_in)*CONTROL_BLEND;
    update_group(s, p, 1, p->v[OBP_HPF_ON] != 0);
    if (s->active[1]) smooth_coeff(&s->filters[0], p->filters[0]);
    unsigned index = (unsigned)((s->clock+i)%OB_ADVANCED_NR_LATENCY);
    for (unsigned ch = 0; ch < 2; ++ch) {
      float x = out[2*i+ch];
      if (!isfinite(x)) { x = 0; atomic_fetch_add_explicit(&s->invalid_samples, 1, memory_order_relaxed); }
      x *= s->gain_in;
      if (s->active[1]) x += (filter(&s->filters[0], x, ch)-x)*s->mix[1];
      s->neural_input[2*i+ch] = x;
      s->neural_dry[2*i+ch] = s->neural_history[index][ch];
      s->neural_history[index][ch] = x;
    }
  }
  if (running) {
    if (!s->neural.process(s->neural.context, s->neural_input, s->neural_output)) return false;
  } else {
    memcpy(s->neural_output, s->neural_dry, sizeof(s->neural_output));
  }
  // Fade off even while the final in-flight neural samples are being drained.
  Prepared current = *p;
  current.v[OBP_NR_ON] = requested ? 1 : 0;
  process_block(s, out, OB_ADVANCED_HOP, &current, 0, true, true, true);
  return true;
}
OBDSPStats ob_dsp_stats(OBDSP *s) {
  OBDSPStats result = {0};
  for (unsigned g = 0; g < OB_DSP_GROUPS; ++g)
    result.reduction_db[g] = from_bits(atomic_load(&s->reduction_bits[g]));
  result.invalid_samples = atomic_load(&s->invalid_samples);
  return result;
}
float ob_dsp_reduction(OBDSP *s, uint32_t group) {
  return group < OB_DSP_GROUPS
      ? from_bits(atomic_load_explicit(&s->reduction_bits[group], memory_order_relaxed))
      : 0;
}
