#import "OBNeural.h"
#import <Accelerate/Accelerate.h>
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { TransformSize = 960, BinCount = 481, StateCount = 90228 };

@interface OBNeuralProcessor : NSObject {
@public
  MLModel *model;
  MLMultiArray *spectrum;
  MLMultiArray *state[2];
  NSData *initialState;
  vDSP_DFT_Setup forward, inverse;
  float window[TransformSize];
  float history[2][TransformSize];
  float overlap[2][TransformSize];
  float even[TransformSize / 2], odd[TransformSize / 2];
  float real[TransformSize / 2], imaginary[TransformSize / 2];
}
@end

@implementation OBNeuralProcessor
- (void)dealloc {
  if (forward) vDSP_DFT_DestroySetup(forward);
  if (inverse) vDSP_DFT_DestroySetup(inverse);
}
@end

static void describe(char *buffer, size_t capacity, NSString *description) {
  if (buffer && capacity) snprintf(buffer, capacity, "%s", description.UTF8String);
}

static bool contiguous(MLMultiArray *array, NSInteger count) {
  if (!array || array.dataType != MLMultiArrayDataTypeFloat32 || array.count != count)
    return false;
  NSInteger stride = 1;
  for (NSInteger i = array.shape.count - 1; i >= 0; --i) {
    if (array.shape[i].integerValue > 1 && array.strides[i].integerValue != stride)
      return false;
    stride *= array.shape[i].integerValue;
  }
  return true;
}

bool ob_neural_reset(OBNeural *opaque) {
  if (!opaque) return false;
  @autoreleasepool {
    OBNeuralProcessor *p = (__bridge OBNeuralProcessor *)(void *)opaque;
    for (unsigned ch = 0; ch < 2; ++ch) {
      NSError *error = nil;
      p->state[ch] = [[MLMultiArray alloc] initWithShape:@[@(StateCount)]
        dataType:MLMultiArrayDataTypeFloat32 error:&error];
      if (!p->state[ch]) return false;
      memcpy(p->state[ch].dataPointer, p->initialState.bytes, StateCount * sizeof(float));
    }
    memset(p->history, 0, sizeof(p->history));
    memset(p->overlap, 0, sizeof(p->overlap));
    return true;
  }
}

OBNeural *ob_neural_create(const char *modelPath, const char *statePath,
                           char *error, size_t capacity) {
  if (!modelPath || !statePath) {
    describe(error, capacity, @"Noise reduction resources are missing.");
    return NULL;
  }
  @autoreleasepool {
    OBNeuralProcessor *p = [OBNeuralProcessor new];
    NSError *failure = nil;
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = MLComputeUnitsCPUOnly;
    p->model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:@(modelPath)]
      configuration:configuration error:&failure];
    if (!p->model) {
      describe(error, capacity, failure.localizedDescription ?: @"Cannot load noise reduction model.");
      return NULL;
    }
    p->initialState = [NSData dataWithContentsOfFile:@(statePath)];
    if (p->initialState.length != StateCount * sizeof(float)) {
      describe(error, capacity, @"Noise reduction initial state is invalid.");
      return NULL;
    }
    p->spectrum = [[MLMultiArray alloc] initWithShape:@[@1,@1,@(BinCount),@2]
      dataType:MLMultiArrayDataTypeFloat32 error:&failure];
    p->forward = vDSP_DFT_zrop_CreateSetup(NULL, TransformSize, vDSP_DFT_FORWARD);
    p->inverse = vDSP_DFT_zrop_CreateSetup(NULL, TransformSize, vDSP_DFT_INVERSE);
    if (!p->spectrum || !p->forward || !p->inverse) {
      describe(error, capacity, @"Cannot prepare noise reduction buffers.");
      return NULL;
    }
    for (unsigned i = 0; i < TransformSize; ++i) {
      double sine = sin(M_PI * (i + 0.5) / TransformSize);
      p->window[i] = (float)sin(M_PI_2 * sine * sine);
    }
    OBNeural *result = (OBNeural *)(__bridge_retained void *)p;
    float silence[OB_NEURAL_HOP * 2] = {0}, output[OB_NEURAL_HOP * 2];
    bool ready = ob_neural_reset(result);
    // Warm both channel paths before the audio worker starts.
    for (unsigned i = 0; i < 8 && ready; ++i)
      ready = ob_neural_process(result, silence, output);
    if (!ready || !ob_neural_reset(result)) {
      describe(error, capacity, @"Noise reduction model validation failed.");
      ob_neural_destroy(result);
      return NULL;
    }
    return result;
  }
}

void ob_neural_destroy(OBNeural *opaque) {
  if (opaque) {
    id released = (__bridge_transfer id)(void *)opaque;
    (void)released;
  }
}

bool ob_neural_process(OBNeural *opaque, const float *input, float *output) {
  if (!opaque || !input || !output) return false;
  @autoreleasepool {
    OBNeuralProcessor *p = (__bridge OBNeuralProcessor *)(void *)opaque;
    for (unsigned ch = 0; ch < 2; ++ch) {
      memmove(p->history[ch], p->history[ch] + OB_NEURAL_HOP, OB_NEURAL_HOP * sizeof(float));
      for (unsigned i = 0; i < OB_NEURAL_HOP; ++i) {
        float sample = input[2*i+ch];
        if (!isfinite(sample)) return false;
        p->history[ch][OB_NEURAL_HOP+i] = sample;
      }
      // vDSP real DFT uses even/odd packing and a factor of two forward scale.
      vDSP_vmul(p->history[ch], 2, p->window, 2, p->even, 1, TransformSize/2);
      vDSP_vmul(p->history[ch]+1, 2, p->window+1, 2, p->odd, 1, TransformSize/2);
      vDSP_DFT_Execute(p->forward, p->even, p->odd, p->real, p->imaginary);
      float *spec = p->spectrum.dataPointer;
      spec[0] = p->real[0] * 0.5f;
      spec[1] = 0;
      spec[2*(BinCount-1)] = p->imaginary[0] * 0.5f;
      spec[2*(BinCount-1)+1] = 0;
      for (unsigned k = 1; k < BinCount-1; ++k) {
        spec[2*k] = p->real[k] * 0.5f;
        spec[2*k+1] = p->imaginary[k] * 0.5f;
      }
      NSError *error = nil;
      MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{@"spec":p->spectrum, @"state_in":p->state[ch]} error:&error];
      id<MLFeatureProvider> prediction = features ? [p->model predictionFromFeatures:features error:&error] : nil;
      MLMultiArray *enhanced = [prediction featureValueForName:@"spec_e"].multiArrayValue;
      MLMultiArray *next = [prediction featureValueForName:@"state_out"].multiArrayValue;
      if (!contiguous(enhanced, BinCount*2) || !contiguous(next, StateCount)) return false;
      const float *e = enhanced.dataPointer;
      for (unsigned k = 0; k < BinCount*2; ++k) if (!isfinite(e[k])) return false;
      p->state[ch] = next;
      p->real[0] = e[0];
      p->imaginary[0] = e[2*(BinCount-1)];
      for (unsigned k = 1; k < BinCount-1; ++k) {
        p->real[k] = e[2*k]; p->imaginary[k] = e[2*k+1];
      }
      vDSP_DFT_Execute(p->inverse, p->real, p->imaginary, p->even, p->odd);
      const float scale = 1.0f / TransformSize;
      for (unsigned i = 0; i < TransformSize/2; ++i) {
        p->overlap[ch][2*i] += p->even[i] * scale * p->window[2*i];
        p->overlap[ch][2*i+1] += p->odd[i] * scale * p->window[2*i+1];
      }
      for (unsigned i = 0; i < OB_NEURAL_HOP; ++i) output[2*i+ch] = p->overlap[ch][i];
      memmove(p->overlap[ch], p->overlap[ch]+OB_NEURAL_HOP, OB_NEURAL_HOP*sizeof(float));
      memset(p->overlap[ch]+OB_NEURAL_HOP, 0, OB_NEURAL_HOP*sizeof(float));
    }
    return true;
  }
}
