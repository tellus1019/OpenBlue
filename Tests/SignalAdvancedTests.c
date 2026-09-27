#include "OBSignal.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static bool unused_process(void *context, const float *input, float *output) {
  (void)context; (void)input; (void)output;
  assert(!"Disabled NR must not invoke prediction");
  return false;
}
static bool reset(void *context) { (void)context; return true; }
int main(void) {
  OBSignal *s = ob_signal_create(); assert(s);
  float v[OBP_COUNT];
  for (unsigned i = 0; i < OBP_COUNT; ++i) {
    const OBParameterInfo *p = ob_parameter_info(i);
    v[i] = p->kind == OB_PARAMETER_BOOLEAN ? 0 : p->initial;
  }
  v[OBP_OUTPUT_GAIN] = 0;
  assert(ob_signal_parameters(s,v,OBP_COUNT));
  assert(ob_signal_advanced(s,(OBAdvancedNR){NULL,unused_process,reset},128));
  assert(ob_signal_latency(s) == 4320);
  float capture[256], output[256];
  unsigned time = 0;
  double energy = 0;
  for (unsigned block = 0; block < 100; ++block) {
    for (unsigned i = 0; i < 128; ++i) {
      capture[2*i] = .2f*sinf((time+i)*.06f);
      capture[2*i+1] = 0;
    }
    time += 128;
    assert(ob_signal_push(s,capture,128));
    ob_signal_render(s,output,128);
    assert(!ob_signal_failed(s));
    for (unsigned i = 0; i < 128; ++i) {
      assert(isfinite(output[2*i]));
      assert(output[2*i+1] == 0);
      energy += output[2*i]*output[2*i];
    }
    usleep(3000);
  }
  assert(energy > 1);
  assert(ob_signal_stats(s).underruns == 0);
  for (unsigned i = 0; i < 100 && !ob_signal_failed(s); ++i) {
    ob_signal_render(s,output,128); usleep(3000);
  }
  assert(ob_signal_failed(s));
  assert(ob_signal_stats(s).underruns == 1);
  for (unsigned i = 0; i < 256; ++i) assert(output[i] == 0);
  ob_signal_destroy(s);
  puts("PASS advanced signal clock bridge, channel isolation and starvation fault");
}
