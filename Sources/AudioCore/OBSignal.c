#include "OBSignal.h"
#include "OBWorker.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CAPACITY 16384u
#define TAPS 32u
#define PHASES 256u
#define CLOCK_POINTS 64u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "Audio requires lock-free counters");

struct OBSignal {
  float samples[CAPACITY][2];
  float coefficients[PHASES][TAPS];
  _Atomic uint64_t written, released;
  _Atomic uint64_t underruns, overruns, clipped, frames;
  _Atomic uint32_t input_peak_bits, output_peak_bits, fill;
  _Atomic uint32_t input_raw_peak_bits, output_raw_peak_bits;
  _Atomic uint32_t input_channel_bits[2], output_channel_bits[2];
  OBDSP *dsp;
  OBWorker *worker;
  double position, clock_error;
  // The producer publishes atomic payloads as well as a sequence number. A
  // bounded reader can reject a concurrent write without a C data race.
  _Atomic uint64_t clock_sequence, clock_sample_bits, clock_host_bits;
  double input_sample[CLOCK_POINTS], input_host[CLOCK_POINTS];
  double output_sample[CLOCK_POINTS], output_host[CLOCK_POINTS];
  unsigned clock_head, clock_count;
  double clock_last_host, clock_input_sample, clock_input_host;
  double clock_output_sample, clock_output_host, clock_rate;
  bool clock_seen;
  float input_meter, output_meter;
  bool primed;
  uint32_t target_frames;
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
  s->target_frames = 512;
  ob_signal_reset(s);
  return s;
}
void ob_signal_destroy(OBSignal *s) {
  if (!s) return;
  ob_worker_destroy(s->worker);
  ob_dsp_destroy(s->dsp);
  free(s);
}
bool ob_signal_set_input_frames(OBSignal *s, uint32_t frames) {
  if (!frames || frames > 8192) return false;
  s->target_frames = frames;
  return true;
}
void ob_signal_reset(OBSignal *s) {
  // Advanced mode owns DSP on a worker; recovery must rebuild the whole path.
  if (s->worker) { ob_worker_fail(s->worker); return; }
  atomic_store(&s->written, 0);
  atomic_store(&s->released, 0);
  atomic_store(&s->underruns, 0);
  atomic_store(&s->overruns, 0);
  atomic_store(&s->clipped, 0);
  atomic_store(&s->frames, 0);
  atomic_store(&s->input_peak_bits, 0);
  atomic_store(&s->output_peak_bits, 0);
  atomic_store(&s->input_raw_peak_bits, 0);
  atomic_store(&s->output_raw_peak_bits, 0);
  for (unsigned ch = 0; ch < 2; ++ch) {
    atomic_store(&s->input_channel_bits[ch], 0);
    atomic_store(&s->output_channel_bits[ch], 0);
  }
  atomic_store(&s->fill, 0);
  ob_dsp_reset(s->dsp);
  s->position = 15;
  s->clock_error = 0;
  s->clock_head = s->clock_count = 0;
  s->clock_last_host = 0;
  s->clock_rate = 1;
  s->clock_seen = false;
  atomic_store(&s->clock_sequence, 0);
  atomic_store(&s->clock_sample_bits, 0);
  atomic_store(&s->clock_host_bits, 0);
  s->input_meter = s->output_meter = 0;
  s->primed = false;
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
static uint64_t double_bits(double value) {
  uint64_t result;
  memcpy(&result, &value, sizeof(result));
  return result;
}
static double double_value(uint64_t value) {
  double result;
  memcpy(&result, &value, sizeof(result));
  return result;
}
void ob_signal_input_time(OBSignal *s, double sample, double host) {
  if (!isfinite(sample) || !isfinite(host) || host <= 0) return;
  uint64_t sequence = atomic_load(&s->clock_sequence);
  atomic_store(&s->clock_sequence, sequence + 1);
  atomic_store(&s->clock_sample_bits, double_bits(sample));
  atomic_store(&s->clock_host_bits, double_bits(host));
  atomic_store(&s->clock_sequence, sequence + 2);
}
static void clock_clear(OBSignal *s) {
  s->clock_head = s->clock_count = 0;
  s->clock_last_host = 0;
  s->clock_rate = 1;
  s->clock_error = 0;
  s->clock_seen = false;
}
static void clock_observe(OBSignal *s, double sample, double host) {
  if (!isfinite(sample) || !isfinite(host) || host <= 0) return;
  uint64_t sequence = atomic_load(&s->clock_sequence);
  if (!sequence || (sequence & 1)) return;
  double in_sample = double_value(atomic_load(&s->clock_sample_bits));
  double in_host = double_value(atomic_load(&s->clock_host_bits));
  if (atomic_load(&s->clock_sequence) != sequence) return;
  // Repeated input points are normal: capture callbacks are less frequent.
  // A backwards clock or a long interruption starts a new estimate.
  if (s->clock_seen &&
      (sample < s->clock_output_sample || host < s->clock_output_host ||
       in_sample < s->clock_input_sample || in_host < s->clock_input_host ||
       host - s->clock_output_host > 0.5 || in_host - s->clock_input_host > 0.5))
    clock_clear(s);
  s->clock_seen = true;
  s->clock_input_sample = in_sample;
  s->clock_input_host = in_host;
  s->clock_output_sample = sample;
  s->clock_output_host = host;
  if (host - s->clock_last_host < 0.03125) return;
  unsigned latest = s->clock_head;
  s->input_sample[latest] = in_sample;
  s->input_host[latest] = in_host;
  s->output_sample[latest] = sample;
  s->output_host[latest] = host;
  s->clock_head = (latest + 1) % CLOCK_POINTS;
  if (s->clock_count < CLOCK_POINTS) ++s->clock_count;
  s->clock_last_host = host;
  unsigned oldest = (s->clock_head + CLOCK_POINTS - s->clock_count) % CLOCK_POINTS;
  double input_seconds = in_host - s->input_host[oldest];
  double output_seconds = host - s->output_host[oldest];
  // Until both spans reach half a second, nominal rate plus slow trim is
  // sufficient for the measured Yeti drift without raising FIFO latency.
  if (input_seconds < 0.5 || output_seconds < 0.5) return;
  double input_rate = (in_sample - s->input_sample[oldest]) / input_seconds;
  double output_rate = (sample - s->output_sample[oldest]) / output_seconds;
  double rate = input_rate / output_rate;
  if (isfinite(rate) && rate >= 0.995 && rate <= 1.005 && output_rate > 0)
    s->clock_rate = rate;
  else
    clock_clear(s);
}
void ob_signal_output_time(OBSignal *s, double sample, double host) {
  clock_observe(s, sample, host);
}
static double clock_ratio(OBSignal *s, double error, uint32_t n) {
  s->clock_error += n / (96000.0 + n) * (error - s->clock_error);
  double trim = fmax(-0.0005, fmin(0.0005, s->clock_error * 1e-6));
  double ratio = fmax(0.995, fmin(1.005, s->clock_rate * (1 + trim)));
  return ratio;
}
static void publish_meters(OBSignal *s, const float input_channels[2], const float output_channels[2], uint32_t n) {
  float input = fmaxf(input_channels[0], input_channels[1]);
  float output = fmaxf(output_channels[0], output_channels[1]);
  for (unsigned ch = 0; ch < 2; ++ch) {
    atomic_store_explicit(&s->input_channel_bits[ch], bits(input_channels[ch]), memory_order_relaxed);
    atomic_store_explicit(&s->output_channel_bits[ch], bits(output_channels[ch]), memory_order_relaxed);
  }
  atomic_store_explicit(&s->input_raw_peak_bits, bits(input), memory_order_relaxed);
  atomic_store_explicit(&s->output_raw_peak_bits, bits(output), memory_order_relaxed);
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
  // A larger output callback must still leave interpolation history in the FIFO.
  uint32_t target = s->target_frames;
  if (target < n + TAPS + 64u) target = n + TAPS + 64u;
  if (!s->primed) {
    uint64_t r = atomic_load_explicit(&s->released, memory_order_relaxed);
    if (w - r < target + n + TAPS) {
      publish_meters(s, (float[2]){0, 0}, (float[2]){0, 0}, n);
      return;
    }
    s->position = (double)w - target - n;
    s->clock_error = 0;
    s->primed = true;
  }
  // Device timestamp slopes determine the rate. Occupancy only removes
  // residual offset: two-second smoothing and one ppm per frame of error.
  double error = (double)w - s->position - (double)n / 2 - target;
  double ratio = clock_ratio(s, error, n);
  if (s->position + n * ratio + 17 >= w) {
    atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
    s->primed = false;
    if (s->worker) ob_worker_fail(s->worker);
    else ob_dsp_discontinuity(s->dsp);
    atomic_store_explicit(&s->released, w > TAPS ? w - TAPS : 0,
                          memory_order_release);
    publish_meters(s, (float[2]){0, 0}, (float[2]){0, 0}, n);
    return;
  }
  float in_peak[2] = {0, 0}, out_peak[2] = {0, 0};
  uint64_t clipped = 0;
  for (uint32_t i = 0; i < n; ++i) {
    uint64_t center = (uint64_t)s->position;
    unsigned phase = (unsigned)((s->position - center) * PHASES);
    for (unsigned ch = 0; ch < 2; ++ch) {
      float sample = 0;
      for (unsigned t = 0; t < TAPS; ++t)
        sample += s->samples[(center - 15 + t) % CAPACITY][ch] *
                  s->coefficients[phase][t];
      in_peak[ch] = fmaxf(in_peak[ch], fabsf(sample));
      out[2 * i + ch] = sample;
    }
    s->position += ratio;
  }
  if (s->worker) ob_worker_process(s->worker, out, n);
  else ob_dsp_process(s->dsp, out, n);
  for (uint32_t i = 0; i < n * 2; ++i) {
    if (fabsf(out[i]) > 1) ++clipped;
    out[i] = isfinite(out[i]) ? fmaxf(-1, fminf(1, out[i])) : 0;
    out_peak[i % 2] = fmaxf(out_peak[i % 2], fabsf(out[i]));
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
                         ob_dsp_stats(s->dsp),
                         s->worker ? ob_worker_late_frames(s->worker) : 0,
                         s->worker ? ob_worker_deadline_misses(s->worker) : 0};
}
OBMeterValues ob_signal_meters(OBSignal *s) {
  return (OBMeterValues){
      .input_left = value(atomic_load_explicit(&s->input_channel_bits[0], memory_order_relaxed)),
      .input_right = value(atomic_load_explicit(&s->input_channel_bits[1], memory_order_relaxed)),
      .output_left = value(atomic_load_explicit(&s->output_channel_bits[0], memory_order_relaxed)),
      .output_right = value(atomic_load_explicit(&s->output_channel_bits[1], memory_order_relaxed)),
      .input_peak = value(atomic_load_explicit(&s->input_peak_bits, memory_order_relaxed)),
      .output_peak = value(atomic_load_explicit(&s->output_peak_bits, memory_order_relaxed)),
      .compressor_reduction = ob_dsp_reduction(s->dsp, 7),
      .limiter_reduction = ob_dsp_reduction(s->dsp, 8),
      .input_raw_peak = value(atomic_load_explicit(&s->input_raw_peak_bits, memory_order_relaxed)),
      .output_raw_peak = value(atomic_load_explicit(&s->output_raw_peak_bits, memory_order_relaxed)),
      .de_esser_reduction = ob_dsp_reduction(s->dsp, 5),
      .de_popper_reduction = ob_dsp_reduction(s->dsp, 6)};
}

bool ob_signal_advanced(OBSignal *s, OBAdvancedNR processor, uint32_t maximum) {
  if (s->worker || !ob_dsp_attach_advanced(s->dsp, processor)) return false;
  s->worker = ob_worker_create(s->dsp, maximum);
  return s->worker != NULL;
}
bool ob_signal_processing(OBSignal *s, const float *v, uint32_t n, float db) {
  return ob_dsp_update_advanced(s->dsp, v, n, db);
}
bool ob_signal_failed(OBSignal *s) { return s->worker && ob_worker_failed(s->worker); }
uint32_t ob_signal_latency(OBSignal *s) {
  return ob_dsp_latency_frames(s->dsp) + (s->worker ? ob_worker_latency(s->worker) : 0);
}
