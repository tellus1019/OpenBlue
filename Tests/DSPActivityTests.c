// Inspect suspended state as well as the audio emitted during wake and fade-out.
#include "../Sources/AudioCore/OBDSP.c"
#include <assert.h>
#include <stdio.h>

static const unsigned switches[] = {0, OBP_HPF_ON, OBP_NR_ON, OBP_GATE_ON,
    OBP_EQ_ON, OBP_ESSER_ON, OBP_POPPER_ON, OBP_COMP_ON, OBP_LIMIT_ON};

static void defaults(float *v) {
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
}

static void dc(OBDSP *s, unsigned frames) {
  for (unsigned i = 0; i < frames; ++i) {
    float audio[] = {.1f, -.05f};
    ob_dsp_process(s, audio, 1);
    assert(isfinite(audio[0]) && isfinite(audio[1]));
    assert(fabsf(audio[1] + .5f*audio[0]) < 1e-5f);
  }
}

static void assert_sleeping(const OBDSP *s) {
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g)
    assert(!s->active[g] && s->mix[g] == 0 && s->preroll[g] == 0);
}

static void suspended_audio(void) {
  OBDSP *s = ob_dsp_create();
  assert(s);
  dc(s, 8192);
  assert_sleeping(s);
  // With every processor off, arbitrary audio still has exactly the fixed delay.
  float history[OB_DSP_LATENCY][2];
  for (unsigned i = 0; i < OB_DSP_LATENCY; ++i) {
    history[i][0] = .1f; history[i][1] = -.05f;
  }
  for (unsigned i = 0; i < 8192; ++i) {
    float audio[] = {.2f*sinf(i*.073f), .1f*cosf(i*.127f)};
    float input[] = {audio[0], audio[1]};
    ob_dsp_process(s, audio, 1);
    for (unsigned ch = 0; ch < 2; ++ch) {
      assert(audio[ch] == history[i%OB_DSP_LATENCY][ch]);
      history[i%OB_DSP_LATENCY][ch] = input[ch];
    }
  }
  // Delay rings advance while the expensive processing state stays untouched.
  for (unsigned f = 0; f < 8; ++f)
    for (unsigned ch = 0; ch < 2; ++ch)
      assert(s->filters[f].x1[ch] == 0 && s->filters[f].y1[ch] == 0);
  assert(s->gate_detector == 0 && s->comp_detector == 0 &&
         s->esser_detector == 0 && s->popper_detector == 0);
  assert(s->queue_head == 0 && s->queue_tail == 0);
  for (unsigned ch = 0; ch < 2; ++ch)
    for (unsigned i = 0; i < FFT_N/2; ++i)
      assert(s->real[ch][i] == 0 && s->imag[ch][i] == 0);
  ob_dsp_destroy(s);
  puts("PASS sleeping processors preserve fixed delay and independent stereo audio");
}

static void wake_and_cancel(void) {
  for (unsigned group = 1; group < OB_DSP_GROUPS; ++group) {
    OBDSP *s = ob_dsp_create();
    assert(s);
    float v[OBP_COUNT]; defaults(v);
    dc(s, 8192);
    v[switches[group]] = 1;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    // No silence or premature wet output while a processor is preparing.
    unsigned preparation = group == 2 ? FFT_N+HOP : group == 8 ? LIMIT_RING : FILTER_PREROLL;
    for (unsigned i = 0; i < preparation; ++i) {
      float audio[] = {.1f, -.05f};
      ob_dsp_process(s, audio, 1);
      assert(fabsf(audio[0]-.1f) < 1e-7f && fabsf(audio[1]+.05f) < 1e-7f);
      assert(s->active[group] && s->mix[group] == 0);
    }
    dc(s, 8192);
    assert(s->active[group] && s->mix[group] == 1);
    v[switches[group]] = 0;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    dc(s, 48);
    assert(s->active[group] && s->mix[group] > 0 && s->mix[group] < 1);
    float mix = s->mix[group];
    v[switches[group]] = 1;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    dc(s, 1);
    assert(s->mix[group] > mix && s->preroll[group] == 0);
    v[switches[group]] = 0;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    dc(s, 8192);
    assert_sleeping(s);
    // An abandoned wake must stop immediately, without a full warm-up cycle.
    v[switches[group]] = 1;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    dc(s, 1);
    assert(s->active[group] && s->preroll[group] > 0);
    v[switches[group]] = 0;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    dc(s, 1);
    assert_sleeping(s);
    ob_dsp_destroy(s);
  }
  puts("PASS each processor wakes, reverses a fade and cancels preparation");
}

static void preset_while_sleeping(void) {
  OBDSP *s = ob_dsp_create();
  assert(s);
  float v[OBP_COUNT]; defaults(v);
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g) v[switches[g]] = 1;
  assert(ob_dsp_update(s, v, OBP_COUNT));
  dc(s, 12000);
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g) v[switches[g]] = 0;
  assert(ob_dsp_update(s, v, OBP_COUNT));
  dc(s, 12000);
  assert_sleeping(s);
  Filter saved[8]; memcpy(saved, s->filters, sizeof(saved));
  float spectrum[2][FFT_N/2]; memcpy(spectrum, s->real, sizeof(spectrum));
  float envelope = s->comp_detector;
  uint64_t queue = s->queue_tail;
  dc(s, 1024);
  assert(!memcmp(saved, s->filters, sizeof(saved)));
  assert(!memcmp(spectrum, s->real, sizeof(spectrum)));
  assert(s->comp_detector == envelope && s->queue_tail == queue);
  // A new preset changes coefficients while sleeping. Wake uses the latest snapshot.
  v[OBP_HPF_HZ] = 400; v[OBP_EQ1_DB] = -12;
  assert(ob_dsp_update(s, v, OBP_COUNT));
  dc(s, 1);
  assert_sleeping(s);
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g) v[switches[g]] = 1;
  assert(ob_dsp_update(s, v, OBP_COUNT));
  dc(s, 1);
  for (unsigned f = 0; f < 8; ++f)
    assert(!memcmp(&s->filters[f].c, &s->slots[s->front].filters[f], sizeof(Coeff)));
  dc(s, 12000);
  for (unsigned g = 1; g < OB_DSP_GROUPS; ++g)
    assert(s->active[g] && s->mix[g] == 1);
  ob_dsp_discontinuity(s);
  assert_sleeping(s);
  ob_dsp_destroy(s);
  puts("PASS preset wake uses current parameters without advancing sleeping state");
}

int main(void) {
  suspended_audio();
  wake_and_cancel();
  preset_while_sleeping();
}
