#include "../Driver/OpenBlueDriver.c"
#include <assert.h>
#include <stdio.h>
static unsigned notifications;
static OSStatus notify(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n,
                       const AudioObjectPropertyAddress *a) {
  notifications += n;
  return noErr;
}
static AudioServerPlugInHostInterface fake_host = {.PropertiesChanged = notify};
static void check(AudioObjectID obj, AudioObjectPropertySelector sel,
                  AudioObjectPropertyScope scope, UInt32 expected) {
  AudioObjectPropertyAddress a = {sel, scope, 0};
  UInt32 bytes = 0, actual = 0;
  char buffer[256];
  assert(interface.HasProperty(driver, obj, 10, &a));
  assert(interface.GetPropertyDataSize(driver, obj, 10, &a, 0, NULL, &bytes) ==
             0 &&
         bytes == expected);
  assert(interface.GetPropertyData(driver, obj, 10, &a, 0, NULL, bytes, &actual,
                                   buffer) == 0 &&
         actual == bytes);
}
int main(void) {
  assert(OpenBlue_Create(NULL, kAudioServerPlugInTypeUUID) == driver);
  assert(initialize(driver, &fake_host) == 0);
  for (unsigned o = PLUGIN; o <= OUTPUT; ++o) {
    check(o, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, 4);
    check(o, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal, 4);
    check(o, kAudioObjectPropertyBaseClass, kAudioObjectPropertyScopeGlobal, 4);
  }
  check(DEVICE, kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal, 8);
  check(DEVICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 4);
  check(DEVICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
        4);
  for (unsigned i = 0; i < 2; ++i) {
    UInt32 scope =
        i ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput;
    check(DEVICE, kAudioDevicePropertyLatency, scope, 4);
    check(DEVICE, kAudioDevicePropertySafetyOffset, scope, 4);
    check(DEVICE, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope, 4);
    check(DEVICE, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope, 4);
  }
  check(DEVICE, kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioValueRange));
  check(INPUT, kAudioStreamPropertyPhysicalFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamBasicDescription));
  check(OUTPUT, kAudioStreamPropertyAvailableVirtualFormats,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamRangedDescription));
  AudioObjectPropertyAddress a = {CLIENTS, kAudioObjectPropertyScopeGlobal, 0};
  Boolean writable = true;
  assert(settable(driver, DEVICE, 10, &a, &writable) == 0 && !writable);
  AudioServerPlugInCustomPropertyInfo info;
  UInt32 actual;
  AudioObjectPropertyAddress list = {kAudioObjectPropertyCustomPropertyInfoList,
                                     kAudioObjectPropertyScopeGlobal, 0};
  assert(get(driver, DEVICE, 10, &list, 0, NULL, sizeof(info), &actual,
             &info) == 0);
  assert(info.mSelector == CLIENTS &&
         info.mPropertyDataType ==
             kAudioServerPlugInCustomPropertyDataTypeCFString);
  AudioServerPlugInClientInfo app = {1, 123, true, CFSTR("org.openblue.app")};
  AudioServerPlugInClientInfo consumer = {2, 456, true,
                                          CFSTR("org.example.recorder")};
  assert(add_client(driver, DEVICE, &app) == 0 &&
         add_client(driver, DEVICE, &consumer) == 0);
  assert(start(driver, DEVICE, 2) == 0 && atomic_load(&consumers) == 1);
  assert(start(driver, DEVICE, 1) == 0 && atomic_load(&consumers) == 1);
  CFStringRef text = NULL;
  assert(get(driver, DEVICE, 10, &a, 0, NULL, sizeof(text), &actual, &text) ==
         0);
  assert(CFEqual(text, CFSTR("1")));
  CFRelease(text);
  float input[512], output[512];
  for (unsigned i = 0; i < 512; ++i)
    input[i] = (float)i / 512;
  AudioServerPlugInIOCycleInfo cycle = {0};
  cycle.mOutputTime.mSampleTime = 10000;
  cycle.mInputTime.mSampleTime = 10000 + OB_LOOP_DELAY;
  assert(io(driver, DEVICE, OUTPUT, 1, kAudioServerPlugInIOOperationWriteMix,
            256, &cycle, input, NULL) == 0);
  assert(io(driver, DEVICE, INPUT, 2, kAudioServerPlugInIOOperationReadInput,
            256, &cycle, output, NULL) == 0);
  assert(memcmp(input, output, sizeof(input)) == 0);
  assert(stop(driver, DEVICE, 2) == 0 && atomic_load(&consumers) == 0);
  assert(stop(driver, DEVICE, 1) == 0 && atomic_load(&running) == 0);
  assert(remove_client(driver, DEVICE, &app) == 0 &&
         remove_client(driver, DEVICE, &consumer) == 0);
  assert(notifications == 4);
  puts("PASS driver interface, custom property contract, client lifecycle and "
       "audio I/O");
}
