#include "OBDSP.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SR 48000
#define PI 3.14159265358979323846
static float config[OBP_COUNT];
static void defaults(void) {
  for (unsigned i = 0; i < OBP_COUNT; ++i) config[i] = ob_parameter_info(i)->initial;
}
static OBDSP *create(void) {
  OBDSP *s = ob_dsp_create();
  assert(s && ob_dsp_update(s, config, OBP_COUNT));
  ob_dsp_reset(s);
  return s;
}
static double level(OBDSP *s, double hz, float amplitude, unsigned frames) {
  float block[256*2];
  double power = 0; unsigned count = 0;
  for (unsigned pos = 0; pos < frames; pos += 256) {
    unsigned n = frames-pos < 256 ? frames-pos : 256;
    for (unsigned i = 0; i < n; ++i) {
      float x = amplitude * (hz == 0 ? 1 : sin(2*PI*hz*(pos+i)/SR));
      block[2*i] = x; block[2*i+1] = -x*.5f;
    }
    ob_dsp_process(s, block, n);
    for (unsigned i = 0; i < n; ++i) {
      assert(isfinite(block[2*i]) && isfinite(block[2*i+1]));
      if (pos+i > frames/2) assert(fabsf(block[2*i+1]+.5f*block[2*i]) < 1e-5f);
      if (pos+i > frames/2) { power += block[2*i]*block[2*i]; ++count; }
    }
  }
  return sqrt(power/count);
}
static double transfer(double hz, float amp) {
  OBDSP *s = create();
  double result = level(s, hz, amp, SR*2);
  ob_dsp_destroy(s);
  return 20*log10(result / (amp*(hz == 0 ? 1 : M_SQRT1_2)));
}
static void parity(void) {
  defaults(); config[OBP_NR_ON] = 1; config[OBP_NR_RANGE] = 0;
  OBDSP *s = create();
  float input[8192], out[8192];
  for (unsigned i = 0; i < 4096; ++i) {
    input[2*i] = .2*sin(2*PI*997*i/SR);
    input[2*i+1] = .1*cos(2*PI*1733*i/SR);
  }
  memcpy(out, input, sizeof(out));
  // Different callback boundaries must give the same fixed delay.
  for (unsigned pos = 0; pos < 4096;) {
    unsigned n = pos%127 + 1; if (n > 4096-pos) n = 4096-pos;
    ob_dsp_process(s, out+2*pos, n); pos += n;
  }
  for (unsigned i = 0; i < 4096; ++i) {
    for (unsigned ch = 0; ch < 2; ++ch) {
      float expected = i < OB_DSP_LATENCY ? 0 : input[2*(i-OB_DSP_LATENCY)+ch];
      assert(fabsf(out[2*i+ch]-expected) < 1e-6f);
    }
  }
  ob_dsp_reset(s); memset(out, 0, sizeof(out)); ob_dsp_process(s, out, 4096);
  for (unsigned i = 0; i < 8192; ++i) assert(out[i] == 0);
  ob_dsp_destroy(s);
  puts("PASS delay, arbitrary callback sizes, stereo separation and reset");
}
static void gain_filters(void) {
  defaults(); config[OBP_INPUT_GAIN] = 6; config[OBP_OUTPUT_GAIN] = -2;
  assert(fabs(transfer(0,.1)-4) < .01);
  defaults(); config[OBP_HPF_ON] = 1; config[OBP_HPF_HZ] = 200;
  assert(fabs(transfer(200,.2)+3.0103) < .05);
  // Bilinear-transform Butterworth magnitude, independent of implementation coefficients.
  double r = tan(PI*50/SR)/tan(PI*200/SR);
  double expected = 20*log10(r*r/sqrt(1+r*r*r*r));
  assert(fabs(transfer(50,.2)-expected) < .2);
  defaults(); config[OBP_EQ_ON] = 1;
  const unsigned gains[] = {OBP_EQ1_DB, OBP_EQ2_DB, OBP_EQ3_DB};
  const unsigned frequencies[] = {OBP_EQ1_HZ, OBP_EQ2_HZ, OBP_EQ3_HZ};
  for (unsigned b = 0; b < 3; ++b) {
    config[gains[b]] = 9;
    assert(fabs(transfer(config[frequencies[b]],.05)-9) < .2);
    config[gains[b]] = -9;
    assert(fabs(transfer(config[frequencies[b]],.05)+9) < .2);
    config[gains[b]] = 0;
  }
  puts("PASS input/output gain, HPF analytical response and all three EQ bands");
}
static void dynamics(void) {
  defaults(); config[OBP_GATE_ON]=1; config[OBP_GATE_THRESHOLD]=-30;
  config[OBP_GATE_RANGE]=40; config[OBP_GATE_RELEASE]=10;
  assert(fabs(transfer(0,.001)+40) < .2);
  assert(fabs(transfer(0,.1)) < .01);
  defaults(); config[OBP_COMP_ON]=1; config[OBP_COMP_THRESHOLD]=-20;
  config[OBP_COMP_RATIO]=4; config[OBP_COMP_ATTACK]=1;
  assert(fabs(transfer(0,.316227766)+7.5) < .2);
  // Ratio 1 is unity, including inside the fixed knee.
  config[OBP_COMP_RATIO]=1;
  assert(fabs(transfer(0,.1)) < .01);
  defaults(); config[OBP_LIMIT_ON]=1; config[OBP_LIMIT_CEILING]=-6;
  OBDSP *s=create();
  float block[512]={0};
  for (unsigned b=0;b<30;++b) ob_dsp_process(s,block,256);
  for (unsigned b=0;b<100;++b) {
    memset(block,0,sizeof(block));
    if (b==0 || b==30) block[20]=block[21]=8;
    if (b>50) for(unsigned i=0;i<512;++i) block[i]=2;
    ob_dsp_process(s,block,256);
    for(unsigned i=0;i<512;++i) {
      if (fabsf(block[i])>powf(10,-6.0/20)+1e-6)
        fprintf(stderr, "Limiter b=%u i=%u output=%.9f ceiling=%.9f\n", b, i, block[i], powf(10,-6.0/20));
      assert(fabsf(block[i])<=powf(10,-6.0/20)+1e-6);
    }
  }
  assert(ob_dsp_stats(s).reduction_db[8]>10);
  ob_dsp_destroy(s);
  puts("PASS gate floor/open state, compressor ratio and limiter impulses/overload");
}
static void limiter_ceiling_change(void) {
  defaults(); config[OBP_LIMIT_ON] = 1;
  OBDSP *s = create();
  (void)level(s, 0, .8, SR/4);
  float ceiling = powf(10, config[OBP_LIMIT_CEILING]/20);
  config[OBP_LIMIT_CEILING] = -12;
  assert(ob_dsp_update(s, config, OBP_COUNT));
  float target = powf(10, -12.0f/20);
  for (unsigned i = 0; i < 2400; ++i) {
    // The specified ceiling transition has a 5 ms exponential time constant.
    ceiling += (target-ceiling)/240;
    if (fabsf(ceiling-target) < 1e-5f) ceiling = target;
    float frame[2] = {.8, -.4};
    ob_dsp_process(s, frame, 1);
    if (fabsf(frame[0]) > ceiling + 1e-6f)
      fprintf(stderr, "Ceiling transition frame=%u output=%f ceiling=%f\n", i, frame[0], ceiling);
    assert(fabsf(frame[0]) <= ceiling + 1e-6f);
  }
  ob_dsp_destroy(s);
  puts("PASS limiter bound during ceiling adjustment");
}
static void band_processing(void) {
  defaults(); config[OBP_ESSER_ON]=1;
  config[OBP_ESSER_HZ]=3000; config[OBP_ESSER_THRESHOLD]=-30;
  config[OBP_ESSER_RANGE]=12; config[OBP_ESSER_ATTACK]=1;
  assert(transfer(10000,.2)<-5);
  assert(fabs(transfer(200,.2))<.2);
  assert(fabs(transfer(10000,.0001))<.1);
  defaults(); config[OBP_POPPER_ON]=1;
  config[OBP_POPPER_HZ]=300; config[OBP_POPPER_THRESHOLD]=-30;
  config[OBP_POPPER_RANGE]=12; config[OBP_POPPER_ATTACK]=.1;
  assert(transfer(50,.2)<-5);
  assert(fabs(transfer(5000,.2))<.2);
  assert(fabs(transfer(50,.0001))<.1);
  puts("PASS de-esser/de-popper target bands and below-threshold preservation");
}
static uint32_t noise_state=42;
static float noise(void) {
  noise_state = 1664525*noise_state + 1013904223;
  return ((noise_state>>8)/8388608.0f - 1)*1.7320508076f;
}
static void noise_reduction(void) {
  defaults(); config[OBP_NR_ON]=1; config[OBP_NR_FLOOR]=-40;
  config[OBP_NR_RANGE]=24;
  OBDSP *s=create();
  float block[512];
  double in=0,out=0;
  for (unsigned b=0;b<400;++b) {
    for (unsigned i=0;i<256;++i) {
      float x=.001f*noise(); block[2*i]=x;block[2*i+1]=x*.5;
      if(b>200)in+=x*x;
    }
    ob_dsp_process(s,block,256);
    if(b>200)for(unsigned i=0;i<256;++i)out+=block[2*i]*block[2*i];
  }
  double attenuation=10*log10(out/in);
  printf("Noise attenuation: %.3f dB\n",attenuation);
  assert(attenuation < -20 && attenuation > -26);
  ob_dsp_destroy(s);
  config[OBP_NR_FLOOR]=-55;
  assert(fabs(transfer(1500,.2))<.2);
  puts("PASS fixed-seed noise attenuation and strong tone preservation");
}
typedef struct { OBDSP *s; _Atomic bool done; } Concurrent;
static void *write_parameters(void *context) {
  Concurrent *c=context; float v[OBP_COUNT];
  for(unsigned i=0;i<OBP_COUNT;++i)v[i]=ob_parameter_info(i)->initial;
  for(unsigned update=0;update<20000;++update) {
    v[OBP_INPUT_GAIN]=update%2 ? -6 : 6;
    v[OBP_OUTPUT_GAIN]=-v[OBP_INPUT_GAIN];
    v[OBP_EQ_ON]=1;v[OBP_EQ1_HZ]=20+(update%480);
    assert(ob_dsp_update(c->s,v,OBP_COUNT));
  }
  atomic_store(&c->done,true); return NULL;
}
static void updates(void) {
  defaults(); OBDSP *s=create();
  float v[OBP_COUNT];memcpy(v,config,sizeof(v));
  v[OBP_HPF_HZ]=NAN; assert(!ob_dsp_update(s,v,OBP_COUNT));
  memcpy(v,config,sizeof(v));v[OBP_HPF_ON]=.5;assert(!ob_dsp_update(s,v,OBP_COUNT));
  assert(!ob_dsp_update(s,config,1));
  Concurrent c={.s=s};pthread_t thread;
  assert(!pthread_create(&thread,NULL,write_parameters,&c));
  float block[512];
  unsigned count=0;
  while(!atomic_load(&c.done)||count<100) {
    for(unsigned i=0;i<512;++i)block[i]=.1;
    ob_dsp_process(s,block,256);
    for(unsigned i=0;i<512;++i)assert(isfinite(block[i])&&fabsf(block[i])<.5);
    if (count % 7 == 0) ob_dsp_discontinuity(s);
    ++count;
  }
  pthread_join(thread,NULL);
  config[OBP_INPUT_GAIN]=12;config[OBP_OUTPUT_GAIN]=12;config[OBP_BYPASS]=1;
  config[OBP_HPF_ON]=config[OBP_NR_ON]=config[OBP_GATE_ON]=config[OBP_EQ_ON]=1;
  config[OBP_ESSER_ON]=config[OBP_POPPER_ON]=config[OBP_COMP_ON]=config[OBP_LIMIT_ON]=1;
  assert(ob_dsp_update(s,config,OBP_COUNT));
  assert(fabs(level(s,997,.1,SR*2)/(.1*M_SQRT1_2)-1)<.001);
  ob_dsp_destroy(s);
  puts("PASS invalid snapshot rejection, concurrent updates and whole-chain bypass");
}
static void timing(void) {
  defaults(); config[OBP_COMP_ON]=1;config[OBP_COMP_THRESHOLD]=-20;
  config[OBP_COMP_RATIO]=4;config[OBP_COMP_ATTACK]=10;config[OBP_COMP_RELEASE]=100;
  OBDSP *s=create();
  (void)level(s,0,.001,SR/4);
  float frame[2];
  for(unsigned i=0;i<512+480;++i) {
    frame[0]=1;frame[1]=.5;
    ob_dsp_process(s,frame,1);
  }
  float attack=ob_dsp_stats(s).reduction_db[7];
  assert(fabsf(attack-15*(1-expf(-1)))<.05);
  (void)level(s,0,1,SR/4);
  float initial=ob_dsp_stats(s).reduction_db[7];
  config[OBP_COMP_RATIO]=1;
  assert(ob_dsp_update(s,config,OBP_COUNT));
  for(unsigned i=0;i<4800;++i) {
    frame[0]=1;frame[1]=.5;ob_dsp_process(s,frame,1);
  }
  assert(fabsf(ob_dsp_stats(s).reduction_db[7]-initial/expf(1))<.05);
  ob_dsp_destroy(s);
  defaults();config[OBP_GATE_ON]=1;config[OBP_GATE_ATTACK]=10;
  config[OBP_GATE_RELEASE]=10;config[OBP_GATE_RANGE]=60;
  s=create();(void)level(s,0,.00001,SR/4);
  initial=ob_dsp_stats(s).reduction_db[3];
  for(unsigned i=0;i<512+480;++i) {
    frame[0]=.5;frame[1]=.25;ob_dsp_process(s,frame,1);
  }
  assert(fabsf(ob_dsp_stats(s).reduction_db[3]-initial/expf(1))<.05);
  ob_dsp_destroy(s);
  puts("PASS compressor attack/release and gate opening time constants");
}
static void gate_hold_release(void) {
  defaults(); config[OBP_GATE_ON] = 1;
  config[OBP_GATE_THRESHOLD] = -30;
  config[OBP_GATE_HOLD] = 20;
  config[OBP_GATE_RELEASE] = 10;
  config[OBP_GATE_RANGE] = 60;
  OBDSP *s = create();
  (void)level(s, 0, .1, SR/4);
  config[OBP_GATE_THRESHOLD] = -6;
  assert(ob_dsp_update(s, config, OBP_COUNT));
  for (unsigned i = 0; i < 960+480; ++i) {
    float frame[2] = {.1, -.05};
    ob_dsp_process(s, frame, 1);
    if (i < 960) assert(ob_dsp_stats(s).reduction_db[3] < .001);
  }
  assert(fabsf(ob_dsp_stats(s).reduction_db[3]-60*(1-expf(-1))) < .05);
  ob_dsp_destroy(s);
  puts("PASS gate hold duration and closing time constant");
}
static void switching(void) {
  defaults();
  const unsigned enabled[] = {OBP_HPF_ON, OBP_NR_ON, OBP_GATE_ON, OBP_EQ_ON,
    OBP_ESSER_ON, OBP_POPPER_ON, OBP_COMP_ON, OBP_LIMIT_ON, OBP_BYPASS};
  config[OBP_INPUT_GAIN] = 6;
  config[OBP_EQ1_DB] = 9;
  OBDSP *s = create();
  (void)level(s, 0, .1, SR/4);
  float last = .1f*powf(10, 6.0f/20);
  for (unsigned stage=0; stage<sizeof(enabled)/sizeof(enabled[0]); ++stage) {
    for (unsigned on=0; on<2; ++on) {
      config[enabled[stage]] = on ? 0 : 1;
      assert(ob_dsp_update(s, config, OBP_COUNT));
      for (unsigned i=0; i<SR/4; ++i) {
        float frame[2] = {.1, -.05};
        ob_dsp_process(s, frame, 1);
        // DC removes the source waveform's slope. A 0.01 step at this
        // level would be a discontinuity far larger than the 5 ms blend.
        assert(fabsf(frame[0]-last) < .01f);
        assert(fabsf(frame[1]+.5f*frame[0]) < 1e-5f);
        last = frame[0];
      }
    }
  }
  ob_dsp_destroy(s);
  puts("PASS each processor and bypass transitions on continuous DC");
}
static void boundaries(void) {
  defaults(); OBDSP *s=create();float block[512];
  for(unsigned p=2;p<OBP_COUNT;++p) {
    const OBParameterInfo *info=ob_parameter_info(p);
    for(unsigned edge=0;edge<2;++edge) {
      config[p]=edge ? info->maximum : info->minimum;
      assert(ob_dsp_update(s,config,OBP_COUNT));
      for(unsigned b=0;b<24;++b) {
        for(unsigned i=0;i<512;++i)block[i]=.01f*sinf(i*.5f);
        ob_dsp_process(s,block,256);
        for(unsigned i=0;i<512;++i)assert(isfinite(block[i]));
      }
    }
    config[p]=info->initial;
  }
  memset(block,0,sizeof(block));block[0]=NAN;block[1]=INFINITY;
  ob_dsp_process(s,block,256);
  assert(ob_dsp_stats(s).invalid_samples==2);
  for(unsigned i=0;i<512;++i)assert(isfinite(block[i]));
  ob_dsp_destroy(s);
  puts("PASS parameter endpoints and non-finite input isolation");
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--concurrency")) { updates(); return 0; }
  parity();gain_filters();dynamics();limiter_ceiling_change();band_processing();noise_reduction();updates();timing();gate_hold_release();switching();boundaries();
  puts("PASS all DSP signal tests; no audio device opened");
}
