#include "OBWorker.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CAPACITY 32768u
struct OBWorker {
  OBDSP *dsp;
  pthread_t thread;
  semaphore_t wake;
  _Atomic bool stopping, failed;
  _Atomic uint64_t written, processed;
  uint64_t position;
  uint32_t maximum, latency;
  float input[CAPACITY][2], output[CAPACITY][2];
};
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2,
               "Worker handoff requires lock-free atomics");
static void *run(void *context) {
  OBWorker *w = context;
  pthread_setname_np("OpenBlue advanced NR");
  // Core ML may allocate and schedule its own work. Keep it off realtime threads.
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  uint64_t read = 0;
  float hop[OB_ADVANCED_HOP * 2];
  while (!atomic_load_explicit(&w->stopping, memory_order_acquire)) {
    if (atomic_load_explicit(&w->failed, memory_order_relaxed)) break;
    uint64_t written = atomic_load_explicit(&w->written, memory_order_acquire);
    if (written-read < OB_ADVANCED_HOP) {
      if (semaphore_wait(w->wake) != KERN_SUCCESS) {
        ob_worker_fail(w); break;
      }
      continue;
    }
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      memcpy(&hop[2*i], w->input[(read+i)%CAPACITY], 2*sizeof(float));
    if (!ob_dsp_process_advanced(w->dsp, hop)) { ob_worker_fail(w); break; }
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      memcpy(w->output[(read+i)%CAPACITY], &hop[2*i], 2*sizeof(float));
    read += OB_ADVANCED_HOP;
    atomic_store_explicit(&w->processed, read, memory_order_release);
  }
  return NULL;
}
OBWorker *ob_worker_create(OBDSP *dsp, uint32_t maximum) {
  if (!dsp || !maximum || maximum > 8192) return NULL;
  OBWorker *w = calloc(1, sizeof(*w));
  if (!w) return NULL;
  w->dsp = dsp; w->maximum = maximum;
  // One callback of collection plus two hops for inference and scheduling.
  w->latency = ((maximum+OB_ADVANCED_HOP-1)/OB_ADVANCED_HOP+2)*OB_ADVANCED_HOP;
  if (semaphore_create(mach_task_self(), &w->wake, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
    free(w); return NULL;
  }
  if (pthread_create(&w->thread, NULL, run, w)) {
    semaphore_destroy(mach_task_self(), w->wake); free(w); return NULL;
  }
  return w;
}
void ob_worker_destroy(OBWorker *w) {
  if (!w) return;
  atomic_store_explicit(&w->stopping, true, memory_order_release);
  semaphore_signal(w->wake);
  pthread_join(w->thread, NULL);
  semaphore_destroy(mach_task_self(), w->wake);
  free(w);
}
uint32_t ob_worker_latency(OBWorker *w) { return w->latency; }
void ob_worker_fail(OBWorker *w) { atomic_store_explicit(&w->failed, true, memory_order_relaxed); }
bool ob_worker_failed(OBWorker *w) { return atomic_load_explicit(&w->failed, memory_order_relaxed); }
bool ob_worker_process(OBWorker *w, float *out, uint32_t n) {
  uint64_t processed = atomic_load_explicit(&w->processed, memory_order_acquire);
  uint64_t end = w->position+n;
  // Checking before publishing this callback guarantees an actual scheduling margin.
  if (ob_worker_failed(w) || n > w->maximum || end-processed > CAPACITY ||
      (end > w->latency && end-w->latency > processed)) {
    ob_worker_fail(w); memset(out, 0, n*2*sizeof(float)); return false;
  }
  for (unsigned i = 0; i < n; ++i) {
    uint64_t index = w->position+i;
    memcpy(w->input[index%CAPACITY], &out[2*i], 2*sizeof(float));
    if (index < w->latency) out[2*i] = out[2*i+1] = 0;
    else memcpy(&out[2*i], w->output[(index-w->latency)%CAPACITY], 2*sizeof(float));
  }
  atomic_store_explicit(&w->written, end, memory_order_release);
  if (end/OB_ADVANCED_HOP != w->position/OB_ADVANCED_HOP)
    if (semaphore_signal(w->wake) != KERN_SUCCESS) ob_worker_fail(w);
  w->position = end;
  return !ob_worker_failed(w);
}
