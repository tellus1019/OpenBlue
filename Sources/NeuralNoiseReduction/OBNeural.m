#import "OBNeural.h"
#import <Accelerate/Accelerate.h>
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { TransformSize = 960, BinCount = 481, DFBinCount = 96,
       StateRows = 144, StateWidth = 512, StateCount = StateRows * StateWidth };

static NSArray<NSNumber *> *erbShape(void) { return @[@2,@1,@1,@(BinCount)]; }
static NSArray<NSNumber *> *specShape(void) { return @[@2,@2,@1,@(DFBinCount)]; }
static NSArray<NSNumber *> *stateShape(void) { return @[@2,@1,@(StateRows),@(StateWidth)]; }
static NSArray<NSNumber *> *coefficientShape(void) { return @[@2,@10,@1,@(DFBinCount)]; }

static bool validArray(MLMultiArray *array, NSArray<NSNumber *> *shape) {
  if (!array || array.dataType != MLMultiArrayDataTypeFloat16 ||
      ![array.shape isEqualToArray:shape] || array.strides.count != shape.count)
    return false;
  for (NSUInteger i = 0; i < shape.count; ++i)
    if (shape[i].integerValue > 1 && array.strides[i].integerValue <= 0) return false;
  return true;
}
static bool contiguousArray(MLMultiArray *array, NSArray<NSNumber *> *shape) {
  if (!validArray(array, shape)) return false;
  NSInteger stride = 1;
  for (NSInteger i = shape.count - 1; i >= 0; --i) {
    if (shape[i].integerValue > 1 && array.strides[i].integerValue != stride) return false;
    stride *= shape[i].integerValue;
  }
  return true;
}
static bool validFeature(MLFeatureDescription *feature, NSArray<NSNumber *> *shape) {
  return feature.type == MLFeatureTypeMultiArray &&
    feature.multiArrayConstraint.dataType == MLMultiArrayDataTypeFloat16 &&
    [feature.multiArrayConstraint.shape isEqualToArray:shape];
}

@interface OBNeuralProcessor : NSObject {
@public
  MLModel *model;
  MLMultiArray *erbFeatures, *complexFeatures;
  MLMultiArray *stateBuffers[2], *stateInput;
  MLMultiArray *maskBacking, *coefficientBacking;
  MLPredictionOptions *options;
  unsigned stateTarget;
  NSData *initialState;
  vDSP_DFT_Setup forward, inverse;
  float window[TransformSize];
  float history[2][TransformSize];
  float overlap[2][TransformSize];
  float normalization[2][BinCount + DFBinCount];
  float spectra[2][3][BinCount][2];
  float masked[2][5][BinCount][2];
  float coefficients[2][3][10][DFBinCount];
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

bool ob_neural_reset(OBNeural *opaque) {
  if (!opaque) return false;
  @autoreleasepool {
    OBNeuralProcessor *p = (__bridge OBNeuralProcessor *)(void *)opaque;
    for (unsigned ch = 0; ch < 2; ++ch)
      memcpy(p->normalization[ch], p->initialState.bytes, sizeof(p->normalization[ch]));
    for (unsigned i = 0; i < 2; ++i)
      memset(p->stateBuffers[i].dataPointer, 0, 2 * StateCount * sizeof(_Float16));
    p->stateInput = p->stateBuffers[0]; p->stateTarget = 1;
    memset(p->history, 0, sizeof(p->history));
    memset(p->overlap, 0, sizeof(p->overlap));
    memset(p->spectra, 0, sizeof(p->spectra));
    memset(p->masked, 0, sizeof(p->masked));
    memset(p->coefficients, 0, sizeof(p->coefficients));
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
    configuration.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    p->model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:@(modelPath)]
      configuration:configuration error:&failure];
    if (!p->model) {
      describe(error, capacity, failure.localizedDescription ?: @"Cannot load noise reduction model.");
      return NULL;
    }
    NSDictionary *inputs = p->model.modelDescription.inputDescriptionsByName;
    NSDictionary *outputs = p->model.modelDescription.outputDescriptionsByName;
    if (inputs.count != 3 || outputs.count != 3 ||
        !validFeature(inputs[@"feat_erb"], erbShape()) ||
        !validFeature(inputs[@"feat_spec"], specShape()) ||
        !validFeature(inputs[@"state_in"], stateShape()) ||
        !validFeature(outputs[@"mask"], erbShape()) ||
        !validFeature(outputs[@"coefs"], coefficientShape()) ||
        !validFeature(outputs[@"state_out"], stateShape())) {
      describe(error, capacity, @"Noise reduction model interface is invalid.");
      return NULL;
    }
    p->initialState = [NSData dataWithContentsOfFile:@(statePath)];
    if (p->initialState.length != (BinCount + DFBinCount) * sizeof(float)) {
      describe(error, capacity, @"Noise reduction initial state is invalid.");
      return NULL;
    }
    const float *initial = p->initialState.bytes;
    for (unsigned i = 0; i < BinCount + DFBinCount; ++i) {
      if (!isfinite(initial[i]) || (i >= BinCount && initial[i] <= 0)) {
        describe(error, capacity, @"Noise reduction normalization state is invalid.");
        return NULL;
      }
    }
    p->erbFeatures = [[MLMultiArray alloc] initWithShape:erbShape()
      dataType:MLMultiArrayDataTypeFloat16 error:&failure];
    p->complexFeatures = [[MLMultiArray alloc] initWithShape:specShape()
      dataType:MLMultiArrayDataTypeFloat16 error:&failure];
    for (unsigned i = 0; i < 2; ++i)
      p->stateBuffers[i] = [[MLMultiArray alloc] initWithShape:stateShape()
        dataType:MLMultiArrayDataTypeFloat16 error:&failure];
    p->maskBacking = [[MLMultiArray alloc] initWithShape:erbShape()
      dataType:MLMultiArrayDataTypeFloat16 error:&failure];
    p->coefficientBacking = [[MLMultiArray alloc] initWithShape:coefficientShape()
      dataType:MLMultiArrayDataTypeFloat16 error:&failure];
    p->options = [MLPredictionOptions new];
    p->forward = vDSP_DFT_zrop_CreateSetup(NULL, TransformSize, vDSP_DFT_FORWARD);
    p->inverse = vDSP_DFT_zrop_CreateSetup(NULL, TransformSize, vDSP_DFT_INVERSE);
    if (!contiguousArray(p->erbFeatures, erbShape()) ||
        !contiguousArray(p->complexFeatures, specShape()) ||
        !contiguousArray(p->stateBuffers[0], stateShape()) ||
        !contiguousArray(p->stateBuffers[1], stateShape()) ||
        !validArray(p->maskBacking, erbShape()) ||
        !validArray(p->coefficientBacking, coefficientShape()) ||
        !p->forward || !p->inverse) {
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
    // Warm the shared stereo model before the audio worker starts.
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

static void prepareFeatures(OBNeuralProcessor *p, const float *input) {
    _Float16 *erb = p->erbFeatures.dataPointer;
    _Float16 *spec = p->complexFeatures.dataPointer;
    for (unsigned ch = 0; ch < 2; ++ch) {
      memmove(p->history[ch], p->history[ch] + OB_NEURAL_HOP, OB_NEURAL_HOP * sizeof(float));
      for (unsigned i = 0; i < OB_NEURAL_HOP; ++i) {
        p->history[ch][OB_NEURAL_HOP+i] = input[2*i+ch];
      }
      // vDSP real DFT uses even/odd packing and a factor of two forward scale.
      vDSP_vmul(p->history[ch], 2, p->window, 2, p->even, 1, TransformSize/2);
      vDSP_vmul(p->history[ch]+1, 2, p->window+1, 2, p->odd, 1, TransformSize/2);
      vDSP_DFT_Execute(p->forward, p->even, p->odd, p->real, p->imaginary);
      memmove(p->spectra[ch][0], p->spectra[ch][1], 2 * BinCount * 2 * sizeof(float));
      float (*spectrum)[2] = p->spectra[ch][2];
      const float scale = 0.5f / TransformSize;
      spectrum[0][0] = p->real[0] * scale; spectrum[0][1] = 0;
      spectrum[BinCount-1][0] = p->imaginary[0] * scale; spectrum[BinCount-1][1] = 0;
      for (unsigned k = 1; k < BinCount-1; ++k) {
        spectrum[k][0] = p->real[k] * scale;
        spectrum[k][1] = p->imaginary[k] * scale;
      }
      for (unsigned k = 0; k < BinCount; ++k) {
        float magnitude = sqrtf(spectrum[k][0]*spectrum[k][0] + spectrum[k][1]*spectrum[k][1]);
        float logarithm = 10 * log10f(magnitude + 1e-10f);
        float mean = 0.98f * p->normalization[ch][k] + 0.02f * logarithm;
        p->normalization[ch][k] = mean;
        erb[ch*BinCount+k] = (_Float16)((logarithm-mean)/40);
        if (k < DFBinCount) {
          float energy = 0.98f * p->normalization[ch][BinCount+k] + 0.02f * magnitude;
          p->normalization[ch][BinCount+k] = energy;
          float divisor = sqrtf(energy + 1e-12f);
          spec[ch*2*DFBinCount+k] = (_Float16)(spectrum[k][0]/divisor);
          spec[ch*2*DFBinCount+DFBinCount+k] = (_Float16)(spectrum[k][1]/divisor);
        }
      }
    }
}

static bool applyEnhancement(OBNeuralProcessor *p, MLMultiArray *mask,
                             MLMultiArray *coefficients, float *output) {
    const _Float16 *gains = mask.dataPointer, *values = coefficients.dataPointer;
    size_t maskChannel = mask.strides[0].unsignedLongValue;
    size_t maskBin = mask.strides[3].unsignedLongValue;
    size_t coefChannel = coefficients.strides[0].unsignedLongValue;
    size_t coefComponent = coefficients.strides[1].unsignedLongValue;
    size_t coefBin = coefficients.strides[3].unsignedLongValue;
    for (unsigned ch = 0; ch < 2; ++ch) {
      memmove(p->masked[ch][0], p->masked[ch][1], 4 * BinCount * 2 * sizeof(float));
      for (unsigned k = 0; k < BinCount; ++k) {
        float gain = (float)gains[ch*maskChannel+k*maskBin];
        if (!isfinite(gain)) return false;
        for (unsigned part = 0; part < 2; ++part)
          p->masked[ch][4][k][part] = p->spectra[ch][0][k][part] * gain;
      }
      memmove(p->coefficients[ch][0], p->coefficients[ch][1], 2 * 10 * DFBinCount * sizeof(float));
      for (unsigned component = 0; component < 10; ++component)
        for (unsigned k = 0; k < DFBinCount; ++k) {
          float value = (float)values[ch*coefChannel+component*coefComponent+k*coefBin];
          if (!isfinite(value)) return false;
          p->coefficients[ch][2][component][k] = value;
        }
      // Keep the official two-hop mask alignment and five-tap complex filter.
      float enhanced[BinCount][2];
      memcpy(enhanced, p->masked[ch][2], sizeof(enhanced));
      for (unsigned k = 0; k < DFBinCount; ++k) {
        float realProduct = 0, imaginaryProduct = 0, crossReal = 0, crossImaginary = 0;
        for (unsigned tap = 0; tap < 5; ++tap) {
          float real = p->masked[ch][tap][k][0], imaginary = p->masked[ch][tap][k][1];
          float realCoef = p->coefficients[ch][0][2*tap][k];
          float imaginaryCoef = p->coefficients[ch][0][2*tap+1][k];
          realProduct += real*realCoef; imaginaryProduct += imaginary*imaginaryCoef;
          crossReal += real*imaginaryCoef; crossImaginary += imaginary*realCoef;
        }
        enhanced[k][0] = realProduct - imaginaryProduct;
        enhanced[k][1] = crossReal + crossImaginary;
      }
      p->real[0] = enhanced[0][0] * TransformSize;
      p->imaginary[0] = enhanced[BinCount-1][0] * TransformSize;
      for (unsigned k = 1; k < BinCount-1; ++k) {
        p->real[k] = enhanced[k][0] * TransformSize;
        p->imaginary[k] = enhanced[k][1] * TransformSize;
      }
      vDSP_DFT_Execute(p->inverse, p->real, p->imaginary, p->even, p->odd);
      const float scale = 1.0f / TransformSize;
      for (unsigned i = 0; i < TransformSize/2; ++i) {
        p->overlap[ch][2*i] += p->even[i] * scale * p->window[2*i];
        p->overlap[ch][2*i+1] += p->odd[i] * scale * p->window[2*i+1];
      }
      for (unsigned i = 0; i < OB_NEURAL_HOP; ++i) {
        if (!isfinite(p->overlap[ch][i])) return false;
        output[2*i+ch] = p->overlap[ch][i];
      }
      memmove(p->overlap[ch], p->overlap[ch]+OB_NEURAL_HOP, OB_NEURAL_HOP*sizeof(float));
      memset(p->overlap[ch]+OB_NEURAL_HOP, 0, OB_NEURAL_HOP*sizeof(float));
    }
    return true;
}

bool ob_neural_process(OBNeural *opaque, const float *input, float *output) {
  if (!opaque || !input || !output) return false;
  for (unsigned i = 0; i < OB_NEURAL_HOP*2; ++i)
    if (!isfinite(input[i])) return false;
  @autoreleasepool {
    OBNeuralProcessor *p = (__bridge OBNeuralProcessor *)(void *)opaque;
    prepareFeatures(p, input);
    NSError *error = nil;
    MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc]
      initWithDictionary:@{@"feat_erb":p->erbFeatures, @"feat_spec":p->complexFeatures,
                           @"state_in":p->stateInput} error:&error];
    p->options.outputBackings = @{@"mask":p->maskBacking, @"coefs":p->coefficientBacking,
                                 @"state_out":p->stateBuffers[p->stateTarget]};
    id<MLFeatureProvider> prediction = features ?
      [p->model predictionFromFeatures:features options:p->options error:&error] : nil;
    MLMultiArray *mask = [prediction featureValueForName:@"mask"].multiArrayValue;
    MLMultiArray *coefficients = [prediction featureValueForName:@"coefs"].multiArrayValue;
    MLMultiArray *next = [prediction featureValueForName:@"state_out"].multiArrayValue;
    if (!validArray(mask, erbShape()) || !validArray(coefficients, coefficientShape()) ||
        !validArray(next, stateShape())) return false;
    // Follow the returned state even when Core ML ignores the requested backing.
    // Never request an output buffer that contains the next prediction's input.
    uintptr_t address = (uintptr_t)next.dataPointer;
    uintptr_t backing = (uintptr_t)p->stateBuffers[p->stateTarget].dataPointer;
    if (next == p->stateBuffers[p->stateTarget] ||
        (address >= backing && address - backing < 2 * StateCount * sizeof(_Float16)))
      p->stateTarget = 1 - p->stateTarget;
    p->stateInput = next;
    return applyEnhancement(p, mask, coefficients, output);
  }
}
