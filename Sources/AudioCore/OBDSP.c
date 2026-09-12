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
#define LOOK 96u
#define LIMIT_RING (LOOK + 1)
#define DIRTY 4u
#define COEFF_BLEND (1.0 / 480.0)
#define CONTROL_BLEND (1.0f / 240.0f)

static const OBParameterInfo parameters[] = {
#define OB_PARAM(id, key, label, unit, group, lo, hi, initial, step) \
  {key, label, unit, group, lo, hi, initial, step},
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
    if (parameters[i].maximum == 1 && parameters[i].minimum == 0 &&
        v[i] != 0 && v[i] != 1) return false;
  }
  return true;
}
typedef struct { double b0, b1, b2, a1, a2; } Coeff;
typedef struct { Coeff c; double x1[2], x2[2], y1[2], y2[2]; } Filter;
typedef struct {
  float v[OBP_COUNT];
  // HPF, three EQ bands, two detection filters, two complementary split LPFs.
  Coeff filters[8];
  float gain_in, gain_out, makeup, nr_power, nr_min, nr_release;
  float gate_attack, gate_release, gate_open, gate_close;
  float esser_attack, esser_release, popper_attack, popper_release;
  float comp_attack, comp_release, ceiling, limit_release;
} Prepared;
struct OBDSP {
#ifdef OB_DSP_PROFILE
  uint64_t profile_ticks[OB_DSP_GROUPS];
#endif
  Prepared slots[3];
  unsigned back, front;
  _Atomic unsigned middle;
  FFTSetup fft;
  Filter filters[8];
  float gain_in, gain_out, makeup, mix[OB_DSP_GROUPS], bypass;
  float input[2][FFT_N], overlap[2][FFT_N * 2], window[FFT_N];
  float real[2][FFT_N], imag[2][FFT_N], spectral_gain[FFT_N / 2 + 1];
  float spectral_target[FFT_N / 2 + 1];
  float nr_dry[2][FFT_N], dry[2][OB_DSP_LATENCY];
  uint64_t clock;
  float gate_detector, gate_db, comp_detector, comp_db;
  float esser_detector, esser_db, popper_detector, popper_db;
  unsigned hold;
  bool gate_open;
  float limit_samples[LIMIT_RING][2], limit_gain, ceiling;
  float peak_queue[128];
  uint64_t peak_time[128], queue_head, queue_tail;
  _Atomic uint32_t reduction_bits[OB_DSP_GROUPS];
  _Atomic uint64_t invalid_samples;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
               "DSP handoff requires lock-free atomics");
static float amplitude(float db) { return powf(10, db / 20); }
static float dbfs(float x) { return 20 * log10f(fmaxf(x, 1e-12f)); }
static float response(float ms) { return expf(-1 / (ms * 0.001f * RATE)); }
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
  } else {
    a0 = 1 + alpha/a;
    c = (Coeff){1+alpha*a, -2*co, 1-alpha*a, -2*co, 1-alpha/a};
  }
  c.b0 /= a0; c.b1 /= a0; c.b2 /= a0; c.a1 /= a0; c.a2 /= a0;
  return c;
}
static Coeff first_order_lowpass(float hz) {
  double k = tan(M_PI * hz / RATE);
  return (Coeff){k / (1 + k), k / (1 + k), 0, (k - 1) / (k + 1), 0};
}
static Prepared prepare(const float *v) {
  Prepared p = {0};
  memcpy(p.v, v, sizeof(p.v));
  p.filters[0] = coefficients(v[OBP_HPF_HZ], M_SQRT1_2, 0, 0);
  for (unsigned i = 0; i < 3; ++i)
    p.filters[i+1] = coefficients(v[OBP_EQ1_HZ+i*3], v[OBP_EQ1_Q+i*3],
                                   v[OBP_EQ1_DB+i*3], 2);
  p.filters[4] = coefficients(v[OBP_ESSER_HZ], M_SQRT1_2, 0, 0);
  p.filters[5] = coefficients(v[OBP_POPPER_HZ], M_SQRT1_2, 0, 1);
  p.filters[6] = first_order_lowpass(v[OBP_ESSER_HZ]);
  p.filters[7] = first_order_lowpass(v[OBP_POPPER_HZ]);
  p.gain_in = amplitude(v[OBP_INPUT_GAIN]);
  p.gain_out = amplitude(v[OBP_OUTPUT_GAIN]);
  p.makeup = amplitude(v[OBP_COMP_MAKEUP]);
  // Expected bin power of white noise through the sqrt-Hann analysis window.
  p.nr_power = powf(10, v[OBP_NR_FLOOR]/10) * FFT_N / 2;
  p.nr_min = amplitude(-v[OBP_NR_RANGE]);
  p.nr_release = expf(-(float)HOP / (v[OBP_NR_RELEASE] * .001f * RATE));
  p.gate_attack = response(v[OBP_GATE_ATTACK]);
  p.gate_release = response(v[OBP_GATE_RELEASE]);
  p.gate_open = amplitude(v[OBP_GATE_THRESHOLD]);
  p.gate_close = amplitude(v[OBP_GATE_THRESHOLD]-3);
  p.esser_attack = response(v[OBP_ESSER_ATTACK]);
  p.esser_release = response(v[OBP_ESSER_RELEASE]);
  p.popper_attack = response(v[OBP_POPPER_ATTACK]);
  p.popper_release = response(v[OBP_POPPER_RELEASE]);
  p.comp_attack = response(v[OBP_COMP_ATTACK]);
  p.comp_release = response(v[OBP_COMP_RELEASE]);
  p.ceiling = amplitude(v[OBP_LIMIT_CEILING]);
  p.limit_release = response(v[OBP_LIMIT_RELEASE]);
  return p;
}
OBDSP *ob_dsp_create(void) {
  OBDSP *s = calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->fft = vDSP_create_fftsetup(9, kFFTRadix2);
  if (!s->fft) { free(s); return NULL; }
  // Warm the in-place transform before the first audio callback.
  DSPSplitComplex warm = {s->real[0], s->imag[0]};
  vDSP_fft_zip(s->fft, &warm, 1, 9, FFT_FORWARD);
  vDSP_fft_zip(s->fft, &warm, 1, 9, FFT_INVERSE);
  for (unsigned i = 0; i < FFT_N; ++i)
    s->window[i] = sqrtf(.5f - .5f*cosf(2*M_PI*i/FFT_N));
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = parameters[i].initial;
  s->slots[0] = s->slots[1] = s->slots[2] = prepare(v);
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
  for (unsigned i = 0; i < 8; ++i) s->filters[i].c = p->filters[i];
  memset(s->input, 0, sizeof(s->input));
  memset(s->overlap, 0, sizeof(s->overlap));
  memset(s->nr_dry, 0, sizeof(s->nr_dry));
  memset(s->dry, 0, sizeof(s->dry));
  memset(s->limit_samples, 0, sizeof(s->limit_samples));
  memset(s->mix, 0, sizeof(s->mix));
  s->clock = s->queue_head = s->queue_tail = 0;
  s->gain_in = p->gain_in; s->gain_out = p->gain_out; s->makeup = p->makeup;
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
  if (!ob_parameters_valid(v, n)) return false;
  s->slots[s->back] = prepare(v);
  s->back = atomic_exchange_explicit(&s->middle, s->back | DIRTY,
                                     memory_order_acq_rel) & 3;
  return true;
}
static void smooth_coeff(Filter *f, Coeff target) {
#define MOVE(field) f->c.field += (target.field - f->c.field) * COEFF_BLEND
  MOVE(b0); MOVE(b1); MOVE(b2); MOVE(a1); MOVE(a2);
#undef MOVE
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
    for (unsigned i = 0; i < FFT_N; ++i) {
      s->real[ch][i] = s->input[ch][(s->clock+1+i)%FFT_N]*s->window[i];
      s->imag[ch][i] = 0;
    }
    DSPSplitComplex z = {s->real[ch], s->imag[ch]};
    vDSP_fft_zip(s->fft, &z, 1, 9, FFT_FORWARD);
  }
  for (unsigned k = 0; k <= FFT_N/2; ++k) {
    float power = 0;
    for (unsigned ch = 0; ch < 2; ++ch)
      power = fmaxf(power, s->real[ch][k]*s->real[ch][k] +
                            s->imag[ch][k]*s->imag[ch][k]);
    s->spectral_target[k] = fmaxf(p->nr_min, 1-p->nr_power/fmaxf(power, 1e-20f));
  }
  for (unsigned k = 0; k <= FFT_N/2; ++k) {
    unsigned left = k ? k-1 : k, right = k < FFT_N/2 ? k+1 : k;
    float target = .25f*s->spectral_target[left] + .5f*s->spectral_target[k]
                   + .25f*s->spectral_target[right];
    float a = target < s->spectral_gain[k] ? .3f : p->nr_release;
    s->spectral_gain[k] = approach(s->spectral_gain[k], target, a);
    for (unsigned ch = 0; ch < 2; ++ch) {
      s->real[ch][k] *= s->spectral_gain[k]; s->imag[ch][k] *= s->spectral_gain[k];
      if (k && k < FFT_N/2) {
        s->real[ch][FFT_N-k] *= s->spectral_gain[k];
        s->imag[ch][FFT_N-k] *= s->spectral_gain[k];
      }
    }
  }
  for (unsigned ch = 0; ch < 2; ++ch) {
    DSPSplitComplex z = {s->real[ch], s->imag[ch]};
    vDSP_fft_zip(s->fft, &z, 1, 9, FFT_INVERSE);
    for (unsigned i = 0; i < FFT_N; ++i)
      s->overlap[ch][(s->clock+1+i)%(FFT_N*2)] +=
          s->real[ch][i] * s->window[i] / FFT_N;
  }
}
static float detector(float previous, float peak) {
  // Peak hold with a 20 ms exponential decay avoids cycle-by-cycle gain chatter.
  return fmaxf(peak, previous * 0.9989588757f);
}
static float band_reduction(float peak, float *envelope, float *reduction,
                            float threshold, float range, float attack, float release) {
  *envelope = detector(*envelope, peak);
  float target = fminf(range, fmaxf(0, dbfs(*envelope)-threshold));
  *reduction = approach(*reduction, target, target > *reduction ? attack : release);
  return amplitude(-*reduction);
}
void ob_dsp_process(OBDSP *s, float *out, uint32_t n) {
  if (atomic_load_explicit(&s->middle, memory_order_acquire) & DIRTY)
    s->front = atomic_exchange_explicit(&s->middle, s->front,
                                        memory_order_acq_rel) & 3;
  const Prepared *p = &s->slots[s->front];
  const float *v = p->v;
  const unsigned enable[] = {0, OBP_HPF_ON, OBP_NR_ON, OBP_GATE_ON, OBP_EQ_ON,
                             OBP_ESSER_ON, OBP_POPPER_ON, OBP_COMP_ON, OBP_LIMIT_ON};
  float reduction[OB_DSP_GROUPS] = {0};
  double nr_in_power = 0, nr_out_power = 0;
  uint64_t invalid = 0;
  for (unsigned i = 0; i < n; ++i, ++s->clock) {
    PROFILE_START;
    float x[2], dry[2];
    for (unsigned ch = 0; ch < 2; ++ch) {
      float input = out[2*i+ch];
      if (!isfinite(input)) { input = 0; ++invalid; }
      dry[ch] = s->dry[ch][s->clock%OB_DSP_LATENCY];
      s->dry[ch][s->clock%OB_DSP_LATENCY] = input;
      x[ch] = input;
    }
    s->gain_in += (p->gain_in-s->gain_in)*CONTROL_BLEND;
    s->gain_out += (p->gain_out-s->gain_out)*CONTROL_BLEND;
    s->makeup += (p->makeup-s->makeup)*CONTROL_BLEND;
    s->ceiling = blend(s->ceiling, p->ceiling);
    s->bypass = blend(s->bypass, v[OBP_BYPASS]);
    for (unsigned g = 1; g < OB_DSP_GROUPS; ++g)
      s->mix[g] = blend(s->mix[g], v[enable[g]]);
    for (unsigned f = 0; f < 8; ++f) smooth_coeff(&s->filters[f], p->filters[f]);
    PROFILE_STAGE(0);
    for (unsigned ch = 0; ch < 2; ++ch) {
      x[ch] *= s->gain_in;
      x[ch] += (filter(&s->filters[0], x[ch], ch)-x[ch])*s->mix[1];
      PROFILE_STAGE(1);
      s->input[ch][s->clock%FFT_N] = x[ch];
      float delayed = s->nr_dry[ch][s->clock%FFT_N];
      s->nr_dry[ch][s->clock%FFT_N] = x[ch];
      float wet = s->overlap[ch][s->clock%(FFT_N*2)];
      s->overlap[ch][s->clock%(FFT_N*2)] = 0;
      x[ch] = delayed + (wet-delayed)*s->mix[2];
      nr_in_power += delayed*delayed; nr_out_power += x[ch]*x[ch];
      PROFILE_STAGE(2);
    }
    if (s->clock%HOP == HOP-1) spectral_frame(s, p);
    PROFILE_STAGE(2);
    float peak = fmaxf(fabsf(x[0]), fabsf(x[1]));
    s->gate_detector = detector(s->gate_detector, peak);
    if (s->gate_detector >= p->gate_open) {
      s->gate_open = true; s->hold = (unsigned)(v[OBP_GATE_HOLD]*48);
    } else if (s->gate_detector < p->gate_close) {
      if (s->hold) --s->hold; else s->gate_open = false;
    }
    float gate_target = s->gate_open ? 0 : v[OBP_GATE_RANGE];
    s->gate_db = approach(s->gate_db, gate_target,
                          gate_target < s->gate_db ? p->gate_attack : p->gate_release);
    float gate = amplitude(-s->gate_db*s->mix[3]);
    reduction[3] = fmaxf(reduction[3], s->gate_db*s->mix[3]);
    PROFILE_STAGE(3);
    for (unsigned ch = 0; ch < 2; ++ch) {
      x[ch] *= gate;
      PROFILE_STAGE(3);
      float eq = x[ch];
      for (unsigned f = 1; f < 4; ++f) eq = filter(&s->filters[f], eq, ch);
      x[ch] += (eq-x[ch])*s->mix[4];
      PROFILE_STAGE(4);
    }
    for (unsigned stage = 0; stage < 2; ++stage) {
      float band[2];
      for (unsigned ch = 0; ch < 2; ++ch)
        band[ch] = filter(&s->filters[4+stage], x[ch], ch);
      float bp = fmaxf(fabsf(band[0]), fabsf(band[1]));
      float gain;
      if (!stage) gain = band_reduction(bp, &s->esser_detector, &s->esser_db,
          v[OBP_ESSER_THRESHOLD], v[OBP_ESSER_RANGE], p->esser_attack, p->esser_release);
      else gain = band_reduction(bp, &s->popper_detector, &s->popper_db,
          v[OBP_POPPER_THRESHOLD], v[OBP_POPPER_RANGE], p->popper_attack, p->popper_release);
      for (unsigned ch = 0; ch < 2; ++ch) {
        float low = filter(&s->filters[6+stage], x[ch], ch);
        float target = stage ? low : x[ch] - low;
        x[ch] += target*(gain-1)*s->mix[5+stage];
      }
      reduction[5+stage] = fmaxf(reduction[5+stage],
                                (stage ? s->popper_db : s->esser_db)*s->mix[5+stage]);
      PROFILE_STAGE(5+stage);
    }
    s->comp_detector = detector(s->comp_detector, fmaxf(fabsf(x[0]), fabsf(x[1])));
    float excess = dbfs(s->comp_detector)-v[OBP_COMP_THRESHOLD];
    float compression = excess <= -3 ? 0 :
        (excess >= 3 ? excess : (excess+3)*(excess+3)/12);
    float comp_target = compression*(1-1/v[OBP_COMP_RATIO]);
    s->comp_db = approach(s->comp_db, comp_target,
                          comp_target > s->comp_db ? p->comp_attack : p->comp_release);
    float comp = amplitude(-s->comp_db);
    comp = 1 + (comp*s->makeup-1)*s->mix[7];
    reduction[7] = fmaxf(reduction[7], s->comp_db*s->mix[7]);
    for (unsigned ch = 0; ch < 2; ++ch) {
      x[ch] *= comp*s->gain_out;
      if (!isfinite(x[ch])) { x[ch] = 0; ++invalid; }
      s->limit_samples[s->clock%LIMIT_RING][ch] = x[ch];
    }
    PROFILE_STAGE(7);
    peak = fmaxf(fabsf(x[0]), fabsf(x[1]));
    while (s->queue_head < s->queue_tail &&
           s->peak_time[s->queue_head%128] + LOOK < s->clock) ++s->queue_head;
    while (s->queue_head < s->queue_tail &&
           s->peak_queue[(s->queue_tail-1)%128] <= peak) --s->queue_tail;
    s->peak_queue[s->queue_tail%128] = peak;
    s->peak_time[s->queue_tail%128] = s->clock;
    ++s->queue_tail;
    float maximum = s->peak_queue[s->queue_head%128];
    float limit = fminf(1, s->ceiling/fmaxf(maximum, 1e-20f));
    // Each observed peak remains in the future window for LOOK+1 frames.
    // Descend from at most unity to its required gain before that peak exits.
    // This avoids an instantaneous cut when a future impulse is discovered.
    s->limit_gain = limit < s->limit_gain ?
        fmaxf(limit, s->limit_gain-(1-limit)/LOOK) :
        approach(s->limit_gain, limit, p->limit_release);
    // A lower user ceiling can arrive after a sample entered lookahead.
    // Follow its smoothed value on the sample being emitted as well.
    unsigned delayed_index = (unsigned)((s->clock+1)%LIMIT_RING);
    float emitted_peak = fmaxf(fabsf(s->limit_samples[delayed_index][0]),
                               fabsf(s->limit_samples[delayed_index][1]));
    s->limit_gain = fminf(s->limit_gain, s->ceiling/fmaxf(emitted_peak, 1e-20f));
    reduction[8] = fmaxf(reduction[8], -dbfs(s->limit_gain)*s->mix[8]);
    float limit_mix = 1 + (s->limit_gain-1)*s->mix[8];
    for (unsigned ch = 0; ch < 2; ++ch) {
      float wet = s->limit_samples[delayed_index][ch]*limit_mix;
      out[2*i+ch] = wet + (dry[ch]-wet)*s->bypass;
    }
    PROFILE_STAGE(8);
  }
  reduction[2] = nr_in_power > 1e-20 ? fmaxf(0, 10*log10(nr_in_power/fmax(nr_out_power,1e-20))) : 0;
  for (unsigned g = 0; g < OB_DSP_GROUPS; ++g)
    atomic_store_explicit(&s->reduction_bits[g], bits(reduction[g]*(1-s->bypass)),
                           memory_order_relaxed);
  atomic_fetch_add_explicit(&s->invalid_samples, invalid, memory_order_relaxed);
}
OBDSPStats ob_dsp_stats(OBDSP *s) {
  OBDSPStats result = {0};
  for (unsigned g = 0; g < OB_DSP_GROUPS; ++g)
    result.reduction_db[g] = from_bits(atomic_load(&s->reduction_bits[g]));
  result.invalid_samples = atomic_load(&s->invalid_samples);
  return result;
}
