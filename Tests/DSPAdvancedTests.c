#include "OBDSP.h"
#include "OBWorker.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  float ring[OB_ADVANCED_NR_LATENCY][2];
  unsigned position, calls, resets;
  bool fail, stall;
  OBDSP *publish_to;
  float next_parameters[OBP_COUNT], next_range;
} Reference;
static bool reset(void *context) {
  Reference *r = context;
  memset(r->ring, 0, sizeof(r->ring)); r->position = 0; ++r->resets;
  return true;
}
static bool predict(void *context, const float *in, float *out) {
  Reference *r = context; ++r->calls;
  if (r->fail) return false;
  if (r->stall) usleep(100000);
  if (r->publish_to) {
    assert(ob_dsp_update_advanced(r->publish_to,r->next_parameters,OBP_COUNT,r->next_range));
    r->publish_to = NULL;
  }
  for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i) {
    for (unsigned ch = 0; ch < 2; ++ch) {
      out[2*i+ch] = r->ring[r->position][ch]*.5f;
      r->ring[r->position][ch] = in[2*i+ch];
    }
    r->position = (r->position+1)%OB_ADVANCED_NR_LATENCY;
  }
  return true;
}
static void parameters(float *v) {
  for (unsigned i = 0; i < OBP_COUNT; ++i) {
    const OBParameterInfo *p = ob_parameter_info(i);
    v[i] = p->kind == OB_PARAMETER_BOOLEAN ? 0 : p->initial;
  }
  v[OBP_OUTPUT_GAIN] = 0;
}
static float sample(unsigned frame, unsigned ch) {
  return .1f*sinf(frame*(ch ? .031f : .047f));
}
static void snapshot_handoff(void) {
  Reference a = {0}, b = {0};
  OBDSP *first = ob_dsp_create(), *second = ob_dsp_create(); assert(first && second);
  assert(ob_dsp_attach_advanced(first,(OBAdvancedNR){&a,predict,reset}));
  assert(ob_dsp_attach_advanced(second,(OBAdvancedNR){&b,predict,reset}));
  float v[OBP_COUNT]; parameters(v); v[OBP_NR_ON] = 1;
  assert(ob_dsp_update_advanced(first,v,OBP_COUNT,6));
  assert(ob_dsp_update_advanced(second,v,OBP_COUNT,6));
  ob_dsp_reset(first); ob_dsp_reset(second);
  float left[OB_ADVANCED_HOP*2], right[OB_ADVANCED_HOP*2];
  for (unsigned block = 0; block < 40; ++block) {
    if (block == 24) {
      // A control update arrives during prediction, after the hop has started.
      memcpy(a.next_parameters,v,sizeof(v));
      a.next_parameters[OBP_OUTPUT_GAIN] = -12; a.next_range = 60;
      a.publish_to = first;
    }
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      for (unsigned ch = 0; ch < 2; ++ch)
        left[2*i+ch] = right[2*i+ch] = sample(block*OB_ADVANCED_HOP+i,ch);
    assert(ob_dsp_process_advanced(first,left));
    assert(ob_dsp_process_advanced(second,right));
    for (unsigned i = 0; i < OB_ADVANCED_HOP*2; ++i) assert(left[i] == right[i]);
    if (block == 24) assert(ob_dsp_update_advanced(second,a.next_parameters,OBP_COUNT,60));
    if (block == 30) {
      assert(!ob_dsp_update_advanced(first,v,OBP_COUNT,NAN));
      assert(!ob_dsp_update_advanced(first,v,OBP_COUNT,61));
    }
  }
  ob_dsp_destroy(first); ob_dsp_destroy(second);
}
int main(void) {
  snapshot_handoff();
  Reference r = {0};
  OBDSP *s = ob_dsp_create(); assert(s);
  assert(ob_dsp_attach_advanced(s, (OBAdvancedNR){&r, predict, reset}));
  float v[OBP_COUNT]; parameters(v);
  float hop[OB_ADVANCED_HOP*2];
  // Disabled NR and global bypass preserve identical latency and stereo identity.
  for (unsigned mode = 0; mode < 3; ++mode) {
    v[OBP_BYPASS] = mode == 1;
    v[OBP_NR_ON] = mode != 0;
    v[OBP_INPUT_GAIN] = mode == 1 ? 6 : 0;
    assert(ob_dsp_update(s, v, OBP_COUNT));
    assert(ob_dsp_update_advanced(s,v,OBP_COUNT, mode == 2 ? 0 : 40));
    ob_dsp_reset(s);
    for (unsigned offset = 0; offset < 14400; offset += OB_ADVANCED_HOP) {
      for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
        for (unsigned ch = 0; ch < 2; ++ch) hop[2*i+ch] = sample(offset+i, ch);
      assert(ob_dsp_process_advanced(s, hop));
      for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
        for (unsigned ch = 0; ch < 2; ++ch) {
          float expected = offset+i < OB_ADVANCED_DSP_LATENCY ? 0 : sample(offset+i-OB_ADVANCED_DSP_LATENCY,ch);
          assert(fabsf(hop[2*i+ch]-expected) < 2e-6f);
        }
    }
    if (mode < 2) assert(r.calls == 0);
  }
  // Prediction receives input gain; the limiter and output gain stay after NR.
  parameters(v); v[OBP_NR_ON] = 1; v[OBP_INPUT_GAIN] = 6; v[OBP_OUTPUT_GAIN] = -6;
  assert(ob_dsp_update(s,v,OBP_COUNT)); assert(ob_dsp_update_advanced(s,v,OBP_COUNT,60)); ob_dsp_reset(s);
  for (unsigned offset = 0; offset < 24000; offset += OB_ADVANCED_HOP) {
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      for (unsigned ch = 0; ch < 2; ++ch) hop[2*i+ch] = sample(offset+i,ch);
    assert(ob_dsp_process_advanced(s,hop));
    if (offset > 12000) for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      for (unsigned ch = 0; ch < 2; ++ch)
        assert(fabsf(hop[2*i+ch]-.5005f*sample(offset+i-OB_ADVANCED_DSP_LATENCY,ch)) < 2e-6f);
  }
  // Suspension and restart reset only neural state, retaining the stream timeline.
  v[OBP_NR_ON] = 0; assert(ob_dsp_update(s,v,OBP_COUNT));
  for (unsigned i = 0; i < 20; ++i) { memset(hop,0,sizeof(hop)); assert(ob_dsp_process_advanced(s,hop)); }
  unsigned calls = r.calls, resets = r.resets;
  assert(ob_dsp_process_advanced(s,hop)); assert(r.calls == calls);
  v[OBP_NR_ON] = 1; assert(ob_dsp_update(s,v,OBP_COUNT));
  assert(ob_dsp_process_advanced(s,hop)); assert(r.resets == resets+1);
  r.fail = true; assert(!ob_dsp_process_advanced(s,hop)); r.fail = false;
  v[OBP_OUTPUT_MUTE] = 1; assert(ob_dsp_update(s,v,OBP_COUNT));
  for (unsigned i = 0; i < 30; ++i) {
    for (unsigned j = 0; j < OB_ADVANCED_HOP*2; ++j) hop[j] = .2f;
    assert(ob_dsp_process_advanced(s,hop));
  }
  for (unsigned i = 0; i < OB_ADVANCED_HOP*2; ++i) assert(hop[i] == 0);
  // The asynchronous path must preserve the advertised delay for variable chunks.
  parameters(v); assert(ob_dsp_update(s,v,OBP_COUNT)); ob_dsp_reset(s);
  OBWorker *worker = ob_worker_create(s, 128); assert(worker);
  assert(ob_worker_latency(worker) == 1440);
  float block[256] = {0};
  unsigned time = 0;
  for (unsigned i = 0; i < 80; ++i) {
    unsigned n = i%3 ? 128 : 97;
    for (unsigned j = 0; j < n; ++j)
      for (unsigned ch = 0; ch < 2; ++ch) block[2*j+ch] = sample(time+j,ch);
    assert(ob_worker_process(worker, block, n));
    for (unsigned j = 0; j < n; ++j)
      for (unsigned ch = 0; ch < 2; ++ch) {
        float expected = time+j < 4320 ? 0 : sample(time+j-4320,ch);
        assert(fabsf(block[2*j+ch]-expected)<2e-6f);
      }
    time += n; usleep(3000);
  }
  ob_worker_destroy(worker);
  // Model failure propagates without substituting unprocessed audio.
  v[OBP_NR_ON] = 1; assert(ob_dsp_update(s,v,OBP_COUNT)); ob_dsp_reset(s); r.fail = true;
  worker = ob_worker_create(s,128); assert(worker);
  for (unsigned i = 0; i < 4; ++i) assert(ob_worker_process(worker,block,128));
  for (unsigned i = 0; i < 100 && !ob_worker_failed(worker); ++i) usleep(1000);
  assert(ob_worker_failed(worker));
  for (unsigned i = 0; i < 256; ++i) block[i] = .25f;
  assert(!ob_worker_process(worker,block,128));
  for (unsigned i = 0; i < 256; ++i) assert(block[i] == 0);
  ob_worker_destroy(worker);
  // An inference stall cannot turn the bounded queue into accumulating latency.
  r.fail = false; r.stall = true; ob_dsp_reset(s);
  worker = ob_worker_create(s,128); assert(worker);
  bool missed = false;
  for (unsigned i = 0; i < 20; ++i) {
    memset(block,0,sizeof(block));
    if (!ob_worker_process(worker,block,128)) { missed = true; break; }
    usleep(3000);
  }
  assert(missed && ob_worker_failed(worker));
  ob_worker_destroy(worker);
  // Match the engine's supported maximum callback size without ring overwrite.
  r.stall = false; parameters(v); assert(ob_dsp_update(s,v,OBP_COUNT)); ob_dsp_reset(s);
  worker = ob_worker_create(s,8192); assert(worker);
  assert(ob_worker_latency(worker) == 9600);
  float *large = calloc(8193*2,sizeof(float)); assert(large);
  assert(ob_worker_process(worker,large,8192));
  assert(!ob_worker_process(worker,large,8193));
  ob_worker_destroy(worker); free(large); ob_dsp_destroy(s);
  puts("Advanced DSP: alignment, gain order, stereo, suspension, failure and worker handoff passed");
}
