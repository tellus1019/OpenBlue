#ifndef OB_DSP_H
#define OB_DSP_H
#include <stdbool.h>
#include <stdint.h>
typedef enum {
#define OB_PARAM(id, key, label, unit, group, lo, hi, initial, step, kind) OBP_##id,
#include "OBParameters.def"
#undef OB_PARAM
  OBP_COUNT
} OBDSPParameter;
typedef enum { OB_PARAMETER_NUMBER, OB_PARAMETER_BOOLEAN, OB_PARAMETER_ENUM } OBParameterKind;
typedef struct {
  const char *key, *label, *unit;
  uint32_t group;
  float minimum, maximum, initial, step;
  OBParameterKind kind;
} OBParameterInfo;
const OBParameterInfo *ob_parameter_info(uint32_t index);
uint32_t ob_parameter_count(void);
bool ob_parameters_valid(const float *values, uint32_t count);

enum { OB_DSP_LATENCY = 992, OB_DSP_GROUPS = 9,
       OB_ADVANCED_HOP = 480, OB_ADVANCED_NR_LATENCY = 2400,
       OB_ADVANCED_DSP_LATENCY = 2880 };
typedef struct {
  void *context;
  bool (*process)(void *context, const float *input, float *output);
  bool (*reset)(void *context);
} OBAdvancedNR;
typedef struct OBDSP OBDSP;
typedef struct {
  float reduction_db[OB_DSP_GROUPS];
  uint64_t invalid_samples;
} OBDSPStats;
// One serialized control writer and one audio reader. Create/destroy/reset
// only while stopped. Update prepares a complete snapshot outside audio.
OBDSP *ob_dsp_create(void);
uint32_t ob_dsp_latency_frames(void);
void ob_dsp_destroy(OBDSP *dsp);
void ob_dsp_reset(OBDSP *dsp);
// Audio reader only: discard stream history after missing input, retaining
// parameters and cumulative fault counters. May overlap a control update.
void ob_dsp_discontinuity(OBDSP *dsp);
bool ob_dsp_update(OBDSP *dsp, const float *values, uint32_t count);
void ob_dsp_process(OBDSP *dsp, float *stereo, uint32_t frames);
// Attach only while stopped. The caller retains the context until DSP destruction.
// Advanced processing requires exactly one hop on a non-realtime worker.
bool ob_dsp_attach_advanced(OBDSP *dsp, OBAdvancedNR processor);
// Publish the complete preset, including advanced reduction, as one snapshot.
bool ob_dsp_update_advanced(OBDSP *dsp, const float *values, uint32_t count, float decibels);
bool ob_dsp_process_advanced(OBDSP *dsp, float *stereo);
OBDSPStats ob_dsp_stats(OBDSP *dsp);
float ob_dsp_reduction(OBDSP *dsp, uint32_t group);
#endif
