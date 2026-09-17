// Offline measurement of the production kernel. No audio device or recording.
#include "../Sources/AudioCore/OBDSP.c"
#include <assert.h>
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>

static double cpu_seconds(void) {
  struct rusage r;
  getrusage(RUSAGE_SELF, &r);
  return r.ru_utime.tv_sec+r.ru_stime.tv_sec+
         (r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6;
}
int main(void) {
  OBDSP *s=ob_dsp_create(); assert(s);
  float values[OBP_COUNT];
  for(unsigned i=0;i<OBP_COUNT;++i) {
    const OBParameterInfo *p=ob_parameter_info(i);
    values[i]=p->initial;
    if(p->minimum==0&&p->maximum==1&&p->group>0)values[i]=1;
  }
  assert(ob_dsp_update(s,values,OBP_COUNT));
  ob_dsp_reset(s);
  const unsigned frames=480000;
  float block[512];
  double start=cpu_seconds(), sum=0;
  uint64_t maximum=0;
  struct timespec a,b;
  for(unsigned pos=0;pos<frames;pos+=256) {
    unsigned n=frames-pos < 256 ? frames-pos : 256;
    for(unsigned i=0;i<n;++i) {
      float x=.2f*sinf(2*M_PI*997*(pos+i)/48000.0);
      block[2*i]=x;block[2*i+1]=x*.5;
    }
    clock_gettime(CLOCK_MONOTONIC_RAW,&a);
    ob_dsp_process(s,block,n);
    clock_gettime(CLOCK_MONOTONIC_RAW,&b);
    uint64_t ns=(b.tv_sec-a.tv_sec)*1000000000ull+b.tv_nsec-a.tv_nsec;
    if(ns>maximum)maximum=ns;
    sum+=block[n];
  }
  printf("audio_seconds=10 rate=48000 block=256 stereo=2 all_processors=enabled\n");
  printf("cpu_seconds=%.6f single_core_equivalent_percent=%.3f max_block_us=%.3f checksum=%.9f\n",
         cpu_seconds()-start,(cpu_seconds()-start)*10,maximum/1000.0,sum);
  printf("kernel_storage_bytes=%zu algorithmic_latency_frames=%d\n",sizeof(*s),OB_DSP_LATENCY);
#ifdef OB_DSP_PROFILE
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  const char *names[]={"Control/InputGain","HPF","NoiseReduction","Gate","EQ",
                        "DeEsser","DePopper","Compressor/OutputGain","Limiter"};
  puts("Instrumented stage timings include timestamp overhead; use normal build for total cost.");
  for(unsigned g=0;g<OB_DSP_GROUPS;++g)
    printf("%s ns_per_stereo_frame=%.3f\n",names[g],
      (double)s->profile_ticks[g]*timebase.numer/timebase.denom/frames);
#endif
  ob_dsp_destroy(s);
}
