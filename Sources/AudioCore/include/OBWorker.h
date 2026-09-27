#ifndef OB_WORKER_H
#define OB_WORKER_H
#include "OBDSP.h"
typedef struct OBWorker OBWorker;
// All lifetime operations run while audio is stopped; DSP remains caller-owned.
OBWorker *ob_worker_create(OBDSP *dsp, uint32_t maximum_callback_frames);
void ob_worker_destroy(OBWorker *worker);
uint32_t ob_worker_latency(OBWorker *worker);
// Single audio producer/consumer. Never waits for the worker or allocates.
// A missed deadline latches a fault and emits silence until the engine is rebuilt.
bool ob_worker_process(OBWorker *worker, float *stereo, uint32_t frames);
void ob_worker_fail(OBWorker *worker);
bool ob_worker_failed(OBWorker *worker);
#endif
