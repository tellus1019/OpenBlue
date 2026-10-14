#include "OBDSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static float sample(unsigned frame, unsigned ch) {
  return .05f * sinf(frame * (ch ? .113f : .071f));
}
static void configure(float *v) {
  for (unsigned i = 0; i < OBP_COUNT; ++i) v[i] = ob_parameter_info(i)->initial;
}
static void alignment(bool on, float attack, bool bypass) {
  float v[OBP_COUNT]; configure(v);
  v[OBP_LIMIT_ON] = on; v[OBP_LIMIT_ATTACK] = attack; v[OBP_BYPASS] = bypass;
  OBDSP *dsp = ob_dsp_create(); assert(dsp);
  assert(ob_dsp_update(dsp,v,OBP_COUNT)); ob_dsp_reset(dsp);
  unsigned delay = 512 + (on ? (unsigned)(attack*48) : 0);
  assert(ob_dsp_latency_frames(dsp) == delay);
  for (unsigned time = 0; time < 24000;) {
    unsigned count = time%113+1;
    float block[226];
    for (unsigned i = 0; i < count; ++i)
      for (unsigned ch = 0; ch < 2; ++ch) block[2*i+ch] = sample(time+i,ch);
    ob_dsp_process(dsp,block,count);
    for (unsigned i = 0; i < count; ++i)
      for (unsigned ch = 0; ch < 2; ++ch) {
        float expected = time+i < delay ? 0 : sample(time+i-delay,ch);
        assert(block[2*i+ch] == expected);
      }
    time += count;
  }
  ob_dsp_destroy(dsp);
}
static void changes(void) {
  float v[OBP_COUNT]; configure(v);
  v[OBP_LIMIT_ON] = 1; v[OBP_LIMIT_CEILING] = -6;
  OBDSP *dsp = ob_dsp_create(); assert(dsp);
  assert(ob_dsp_update(dsp,v,OBP_COUNT)); ob_dsp_reset(dsp);
  float previous = 0;
  // Continuous DC exposes a discontinuity independently of waveform slope.
  for (unsigned time = 0; time < 40000; ++time) {
    if (time == 12000 || time == 12120 || time == 12500) {
      v[OBP_LIMIT_ATTACK] = time == 12000 ? 10 : time == 12120 ? 0 : 5;
      assert(ob_dsp_update(dsp,v,OBP_COUNT));
    }
    if (time == 16000) { v[OBP_BYPASS] = 1; assert(ob_dsp_update(dsp,v,OBP_COUNT)); }
    if (time == 20000) { v[OBP_LIMIT_ON] = 0; assert(ob_dsp_update(dsp,v,OBP_COUNT)); }
    float frame[] = {.1f,-.05f}; ob_dsp_process(dsp,frame,1);
    if (time > 11000) assert(fabsf(frame[0]-previous) < 1e-6f);
    assert(fabsf(frame[1]+.5f*frame[0]) < 1e-7f);
    if (time == 12240) assert(ob_dsp_latency_frames(dsp) == 512);
    if (time == 12740) assert(ob_dsp_latency_frames(dsp) == 752);
    if (time > 24000) assert(ob_dsp_latency_frames(dsp) == 512);
    previous = frame[0];
  }
  ob_dsp_destroy(dsp);
}
static void lookahead_ceiling(void) {
  float v[OBP_COUNT]; configure(v);
  v[OBP_LIMIT_ON] = 1; v[OBP_LIMIT_CEILING] = -6;
  OBDSP *dsp = ob_dsp_create(); assert(dsp);
  assert(ob_dsp_update(dsp,v,OBP_COUNT)); ob_dsp_reset(dsp);
  const float ceiling = powf(10,-6.0f/20);
  for (unsigned time = 0; time < 30000; ++time) {
    if (time == 12000 || time == 12120 || time == 12500) {
      v[OBP_LIMIT_ATTACK] = time == 12000 ? 10 : time == 12120 ? 0 : 5;
      assert(ob_dsp_update(dsp,v,OBP_COUNT));
    }
    float frame[] = {2*sinf(time*.043f), 1.5f*cosf(time*.077f)};
    ob_dsp_process(dsp,frame,1);
    if (time > 10000) for (unsigned ch = 0; ch < 2; ++ch)
      assert(isfinite(frame[ch]) && fabsf(frame[ch]) <= ceiling+1e-6f);
  }
  ob_dsp_destroy(dsp);
}
int main(void) {
  const float attacks[] = {0,2,5,10};
  for (unsigned i = 0; i < 4; ++i) {
    alignment(true,attacks[i],false); alignment(true,attacks[i],true);
  }
  alignment(false,10,false); alignment(false,10,true);
  changes(); lookahead_ceiling();
  puts("PASS variable lookahead, stereo/bypass alignment, rapid edits and delay publication");
}
