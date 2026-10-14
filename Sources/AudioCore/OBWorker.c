#include "OBWorker.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#if OB_DIAGNOSTICS
#include <os/log.h>
#endif
#include <os/workgroup.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CAPACITY 32768u
#define INFERENCE_BUDGET_FRAMES 408u
struct OBWorker {
  OBDSP *dsp;
  pthread_t thread;
  semaphore_t wake, ready;
  os_workgroup_interval_t workgroup;
  uint64_t period_ticks;
  _Atomic bool stopping, failed;
  _Atomic uint64_t written, processed;
  _Atomic uint64_t late_frames, deadline_misses;
#if OB_DIAGNOSTICS
  _Atomic unsigned failure_reason;
  uint32_t failure_frames;
  uint64_t failure_position, failure_processed, longest_hop_ticks;
#endif
  uint64_t position;
  uint32_t maximum, latency, startup_silence;
  float last_output[2], dropout_start[2];
  unsigned fade_remaining;
  bool dropping;
  float input[CAPACITY][2], output[CAPACITY][2];
};
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2 &&
               ATOMIC_INT_LOCK_FREE == 2,
               "Worker handoff requires lock-free atomics");
enum { SIGNAL_FAILURE = 1, WAIT_FAILURE, PREDICTION_FAILURE,
       CALLBACK_TOO_LARGE, RING_OVERFLOW, WAKE_FAILURE = 7,
       THREAD_SETUP_FAILURE, INTERVAL_FAILURE };
static void fail(OBWorker *w, unsigned reason, uint32_t frames,
                 uint64_t position, uint64_t processed) {
#if OB_DIAGNOSTICS
  unsigned expected = 0;
  if (atomic_compare_exchange_strong_explicit(&w->failure_reason, &expected, reason,
                                              memory_order_relaxed, memory_order_relaxed)) {
    w->failure_frames = frames;
    w->failure_position = position;
    w->failure_processed = processed;
  }
#else
  (void)reason; (void)frames; (void)position; (void)processed;
#endif
  atomic_store_explicit(&w->failed, true, memory_order_relaxed);
}
static void *run(void *context) {
  OBWorker *w = context;
  pthread_setname_np("OpenBlue advanced NR");
  // This worker has a 10 ms cadence independent of the device callback.
  // Core ML stays outside callbacks; the rings never wait for inference.
  thread_time_constraint_policy_data_t policy = {
    .period = (uint32_t)w->period_ticks,
    .computation = (uint32_t)(w->period_ticks * 2 / 5),
    .constraint = (uint32_t)w->period_ticks,
    .preemptible = true
  };
  os_workgroup_join_token_s token;
  bool joined = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0 &&
      thread_policy_set(pthread_mach_thread_np(pthread_self()),
                        THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                        THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_SUCCESS &&
      os_workgroup_join(w->workgroup, &token) == 0;
  if (!joined) fail(w, THREAD_SETUP_FAILURE, 0, 0, 0);
  semaphore_signal(w->ready);
  if (!joined) return NULL;
  uint64_t read = 0;
  float hop[OB_ADVANCED_HOP * 2];
  while (!atomic_load_explicit(&w->stopping, memory_order_acquire)) {
    if (atomic_load_explicit(&w->failed, memory_order_relaxed)) break;
    uint64_t written = atomic_load_explicit(&w->written, memory_order_acquire);
    if (written-read < OB_ADVANCED_HOP) {
      if (semaphore_wait(w->wake) != KERN_SUCCESS) {
        fail(w, WAIT_FAILURE, 0, read, read); break;
      }
      continue;
    }
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      memcpy(&hop[2*i], w->input[(read+i)%CAPACITY], 2*sizeof(float));
    uint64_t started = mach_absolute_time();
    if (os_workgroup_interval_start(w->workgroup, started,
                                    started + w->period_ticks, NULL)) {
      fail(w, INTERVAL_FAILURE, OB_ADVANCED_HOP, read, read); break;
    }
    bool success = ob_dsp_process_advanced(w->dsp, hop);
    int finished = os_workgroup_interval_finish(w->workgroup, NULL);
#if OB_DIAGNOSTICS
    uint64_t elapsed = mach_absolute_time() - started;
    if (elapsed > w->longest_hop_ticks) w->longest_hop_ticks = elapsed;
#endif
    if (!success) { fail(w, PREDICTION_FAILURE, OB_ADVANCED_HOP, read, read); break; }
    if (finished) { fail(w, INTERVAL_FAILURE, OB_ADVANCED_HOP, read, read); break; }
    for (unsigned i = 0; i < OB_ADVANCED_HOP; ++i)
      memcpy(w->output[(read+i)%CAPACITY], &hop[2*i], 2*sizeof(float));
    read += OB_ADVANCED_HOP;
    atomic_store_explicit(&w->processed, read, memory_order_release);
  }
  os_workgroup_leave(w->workgroup, &token);
  return NULL;
}
OBWorker *ob_worker_create(OBDSP *dsp, uint32_t maximum) {
  if (!dsp || !maximum || maximum > 8192) return NULL;
  OBWorker *w = calloc(1, sizeof(*w));
  if (!w) return NULL;
  w->dsp = dsp; w->maximum = maximum;
  w->startup_silence = ob_dsp_startup_silence_frames(dsp);
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer) {
    free(w); return NULL;
  }
  w->period_ticks = UINT64_C(10000000) * timebase.denom / timebase.numer;
  w->workgroup = AudioWorkIntervalCreate("OpenBlue advanced NR",
                                        OS_CLOCK_MACH_ABSOLUTE_TIME, NULL);
  if (!w->workgroup) { free(w); return NULL; }
  // A hop to collect input, one callback to publish it, and an 8.5 ms inference budget.
  w->latency = OB_ADVANCED_HOP + maximum + INFERENCE_BUDGET_FRAMES;
  if (semaphore_create(mach_task_self(), &w->wake, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
    os_release(w->workgroup); free(w); return NULL;
  }
  if (semaphore_create(mach_task_self(), &w->ready, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
    semaphore_destroy(mach_task_self(), w->wake);
    os_release(w->workgroup); free(w); return NULL;
  }
  if (pthread_create(&w->thread, NULL, run, w)) {
    semaphore_destroy(mach_task_self(), w->ready);
    semaphore_destroy(mach_task_self(), w->wake);
    os_release(w->workgroup); free(w); return NULL;
  }
  if (semaphore_wait(w->ready) != KERN_SUCCESS || ob_worker_failed(w)) {
    ob_worker_destroy(w); return NULL;
  }
  return w;
}
void ob_worker_destroy(OBWorker *w) {
  if (!w) return;
  atomic_store_explicit(&w->stopping, true, memory_order_release);
  semaphore_signal(w->wake);
  pthread_join(w->thread, NULL);
  os_release(w->workgroup);
  semaphore_destroy(mach_task_self(), w->ready);
#if OB_DIAGNOSTICS
  unsigned reason = atomic_load_explicit(&w->failure_reason, memory_order_relaxed);
  if (reason) {
    // Both audio and inference are stopped before reading the fault snapshot.
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    os_log_t log = os_log_create("org.openblue.app", "Audio");
    os_log_error(log,
      "Advanced NR fault reason=%u frames=%u position=%llu processed=%llu maximum=%u latency=%u longest_hop_ms=%.3f",
      reason, w->failure_frames, w->failure_position, w->failure_processed,
      w->maximum, w->latency,
      w->longest_hop_ticks * (double)timebase.numer / timebase.denom / 1e6);
    os_release(log);
  }
#endif
  semaphore_destroy(mach_task_self(), w->wake);
  free(w);
}
uint32_t ob_worker_latency(OBWorker *w) { return w->latency; }
void ob_worker_fail(OBWorker *w) { fail(w, SIGNAL_FAILURE, 0, 0, 0); }
bool ob_worker_failed(OBWorker *w) { return atomic_load_explicit(&w->failed, memory_order_relaxed); }
uint64_t ob_worker_late_frames(OBWorker *w) {
  return atomic_load_explicit(&w->late_frames, memory_order_relaxed);
}
uint64_t ob_worker_deadline_misses(OBWorker *w) {
  return atomic_load_explicit(&w->deadline_misses, memory_order_relaxed);
}
bool ob_worker_process(OBWorker *w, float *out, uint32_t n) {
  uint64_t processed = atomic_load_explicit(&w->processed, memory_order_acquire);
  uint64_t end = w->position+n;
  // A temporary scheduling delay must not restart the model and both audio units.
  unsigned reason = n > w->maximum ? CALLBACK_TOO_LARGE :
      end-processed > CAPACITY ? RING_OVERFLOW : 0;
  if (ob_worker_failed(w) || reason) {
    if (reason) fail(w, reason, n, w->position, processed);
    memset(out, 0, n*2*sizeof(float)); return false;
  }
  uint64_t late = 0, misses = 0;
  for (unsigned i = 0; i < n; ++i) {
    uint64_t index = w->position+i;
    memcpy(w->input[index%CAPACITY], &out[2*i], 2*sizeof(float));
    // Causal DSP history is zero before the first audible frame. Emit that
    // known prefix without waiting for predictions whose output is inaudible.
    if (index < w->latency + w->startup_silence) out[2*i] = out[2*i+1] = 0;
    else if (index-w->latency >= processed) {
      ++late;
      if (!w->dropping) {
        w->dropping = true; ++misses; w->fade_remaining = 48;
        memcpy(w->dropout_start, w->last_output, sizeof(w->last_output));
      }
      // A one millisecond ramp limits the discontinuity without replaying speech.
      if (w->fade_remaining) --w->fade_remaining;
      for (unsigned ch = 0; ch < 2; ++ch)
        out[2*i+ch] = w->dropout_start[ch] * (w->fade_remaining / 48.0f);
    } else {
      if (w->dropping) { w->dropping = false; w->fade_remaining = 48; }
      float gain = 1;
      if (w->fade_remaining) gain = 1 - (--w->fade_remaining / 48.0f);
      for (unsigned ch = 0; ch < 2; ++ch)
        out[2*i+ch] = w->output[(index-w->latency)%CAPACITY][ch] * gain;
    }
    memcpy(w->last_output, &out[2*i], sizeof(w->last_output));
  }
  atomic_fetch_add_explicit(&w->late_frames, late, memory_order_relaxed);
  atomic_fetch_add_explicit(&w->deadline_misses, misses, memory_order_relaxed);
  atomic_store_explicit(&w->written, end, memory_order_release);
  if (end/OB_ADVANCED_HOP != w->position/OB_ADVANCED_HOP)
    if (semaphore_signal(w->wake) != KERN_SUCCESS)
      fail(w, WAKE_FAILURE, n, w->position, processed);
  w->position = end;
  return !ob_worker_failed(w);
}
