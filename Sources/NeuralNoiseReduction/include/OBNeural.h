#ifndef OB_NEURAL_H
#define OB_NEURAL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { OB_NEURAL_HOP = 480, OB_NEURAL_LATENCY = 2400 };
typedef struct OBNeural OBNeural;

// Control/worker thread only. These functions may allocate and block.
// One model shares immutable weights between two independent channel states.
OBNeural *ob_neural_create(const char *compiled_model_path,
                           const char *initial_state_path,
                           char *error, size_t error_capacity);
void ob_neural_destroy(OBNeural *processor);
bool ob_neural_reset(OBNeural *processor);
// Exactly one interleaved stereo hop at 48 kHz. In-place processing is supported.
// No concurrent calls, including reset and destroy. Failure never returns dry audio.
bool ob_neural_process(OBNeural *processor, const float *input, float *output);
#endif
