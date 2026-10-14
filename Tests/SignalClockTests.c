#include "../Sources/AudioCore/OBSignal.c"
#include <assert.h>
#include <stdio.h>
static void points(OBSignal *s,double origin,double ppm) {
 for(unsigned k=0;k<96;++k) {
  double t=origin+k*0.032;
  ob_signal_input_time(s,(t-origin)*48000*(1+ppm/1e6),t);
  ob_signal_output_time(s,(t-origin)*48000,t);
 }
 assert(fabs(s->clock_rate-(1+ppm/1e6))<1e-9);
 assert(fabs(clock_ratio(s,0,48)-(1+ppm/1e6))<1e-9);
}
int main(void) {
 OBSignal *s=ob_signal_create();assert(s);
 ob_signal_input_time(s,0,1);ob_signal_output_time(s,0,1);
 ob_signal_input_time(s,4800.3168,1.1);ob_signal_output_time(s,4800,1.1);
 assert(s->clock_rate==1);
 points(s,2,66);
 // A repeated timestamp is not a device reset.
 unsigned count=s->clock_count;
 ob_signal_output_time(s,s->clock_output_sample,s->clock_output_host);
 assert(s->clock_count==count && fabs(s->clock_rate-1.000066)<1e-9);
 // A mailbox being written is skipped once, never spun on.
 uint64_t sequence=atomic_load(&s->clock_sequence);
 atomic_store(&s->clock_sequence,sequence+1);
 ob_signal_output_time(s,999999,10);
 assert(s->clock_count==count);
 atomic_store(&s->clock_sequence,sequence);
 // Non-finite and absent clock representations cannot poison the estimate.
 ob_signal_input_time(s,NAN,20);ob_signal_output_time(s,0,NAN);
 assert(fabs(s->clock_rate-1.000066)<1e-9);
 // Device timestamp reset discards the old rate and trim.
 ob_signal_input_time(s,0,6);ob_signal_output_time(s,0,6);
 assert(s->clock_rate==1 && s->clock_count==1 && s->clock_error==0);
 points(s,7,-66);
 ob_signal_reset(s);
 assert(!s->clock_seen && s->clock_count==0 && s->clock_rate==1 && clock_ratio(s,0,48)==1);
 // A new route after a nominal format change starts with empty clock history.
 ob_signal_destroy(s);s=ob_signal_create();assert(s && s->clock_count==0 && s->clock_rate==1);
 ob_signal_destroy(s);puts("PASS clock startup, repeated/invalid timestamps, bounded mailbox, discontinuity and route reset");
}
