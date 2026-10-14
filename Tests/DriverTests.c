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
static void check_string(AudioObjectID obj, AudioObjectPropertySelector sel,
                         CFStringRef expected) {
  AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, 0};
  UInt32 bytes = 0, actual = 0;
  CFStringRef value = NULL;
  Boolean writable = true;
  assert(interface.HasProperty(driver, obj, 10, &a));
  assert(interface.IsPropertySettable(driver, obj, 10, &a, &writable) == 0 && !writable);
  assert(interface.GetPropertyDataSize(driver, obj, 10, &a, 0, NULL, &bytes) == 0 &&
         bytes == sizeof(value));
  assert(interface.GetPropertyData(driver, obj, 10, &a, 0, NULL, bytes, &actual,
                                   &value) == 0 && actual == bytes);
  assert(CFEqual(value, expected));
  CFRelease(value);
}
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
static void latency(void) {
  UInt32 actual;
  AudioObjectPropertyAddress latency_address = {kAudioDevicePropertyLatency,
      kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
  UInt32 input_latency = 0;
  assert(get(driver, DEVICE, 0, &latency_address, 0, NULL,
             sizeof(input_latency), &actual, &input_latency) == 0);
  assert(input_latency == 64 && input_latency == OB_LOOP_DELAY);
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
  ob_loop_clear(&loop);
  // Read first at each 48-frame callback: all delayed samples must already exist.
  for (unsigned t = 0; t < 4800; t += 48) {
    cycle.mInputTime.mSampleTime = t;
    assert(io(driver, DEVICE, INPUT, 2, kAudioServerPlugInIOOperationReadInput,
              48, &cycle, output, NULL) == noErr);
    for (unsigned i = 0; i < 48; ++i) {
      float expected = t+i < 64 ? 0 : (t+i-64+1)*0.0001f;
      assert(output[2*i] == expected && output[2*i+1] == -expected);
      input[2*i] = (t+i+1)*0.0001f; input[2*i+1] = -input[2*i];
    }
    cycle.mOutputTime.mSampleTime = t;
    assert(io(driver, DEVICE, OUTPUT, 1, kAudioServerPlugInIOOperationWriteMix,
              48, &cycle, input, NULL) == noErr);
  }
}
int main(int argc, char **argv) {
  assert(OpenBlue_Create(NULL, kAudioServerPlugInTypeUUID) == driver);
  assert(initialize(driver, &fake_host) == 0);
  if (argc == 2 && !strcmp(argv[1], "--latency")) {
    latency(); puts("PASS 64-frame loopback, published latency and read-before-write callbacks"); return 0;
  }
  for (unsigned o = PLUGIN; o <= OUTPUT; ++o) {
    check(o, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, 4);
    check(o, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal, 4);
    check(o, kAudioObjectPropertyBaseClass, kAudioObjectPropertyScopeGlobal, 4);
    check_string(o, kAudioObjectPropertyManufacturer, CFSTR("OpenBlue"));
    check_string(o, kAudioObjectPropertyName,
                 o == INPUT ? CFSTR("OpenBlue Input") :
                 o == OUTPUT ? CFSTR("OpenBlue Feed") : CFSTR("OpenBlue"));
    check(o, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
          o == PLUGIN ? 4 : o == DEVICE ? 8 : 0);
  }
  check_string(PLUGIN, kAudioPlugInPropertyBundleID, CFSTR("org.openblue.driver"));
  check_string(PLUGIN, kAudioPlugInPropertyResourceBundle, CFSTR(""));
  check_string(DEVICE, kAudioDevicePropertyDeviceUID, CFSTR("org.openblue.virtual-device"));
  check_string(DEVICE, kAudioDevicePropertyModelUID, CFSTR("org.openblue.virtual-model"));
  check(PLUGIN, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 4);
  check(PLUGIN, kAudioPlugInPropertyBoxList, kAudioObjectPropertyScopeGlobal, 0);
  AudioObjectPropertyAddress translate = {kAudioPlugInPropertyTranslateUIDToDevice,
                                          kAudioObjectPropertyScopeGlobal, 0};
  CFStringRef uid = CFSTR("org.openblue.virtual-device");
  UInt32 translated = 0, translated_size = 0;
  assert(interface.HasProperty(driver, PLUGIN, 10, &translate));
  assert(interface.GetPropertyDataSize(driver, PLUGIN, 10, &translate,
                                       sizeof(uid), &uid, &translated_size) == 0 &&
         translated_size == sizeof(translated));
  assert(interface.GetPropertyData(driver, PLUGIN, 10, &translate, sizeof(uid), &uid,
                                   sizeof(translated), &translated_size, &translated) == 0 &&
         translated == DEVICE);
  const AudioObjectPropertySelector scalars[] = {
      kAudioDevicePropertyTransportType, kAudioDevicePropertyClockDomain,
      kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
      kAudioDevicePropertyIsHidden, kAudioDevicePropertyZeroTimeStampPeriod};
  for (unsigned i = 0; i < sizeof(scalars) / sizeof(scalars[0]); ++i)
    check(DEVICE, scalars[i], kAudioObjectPropertyScopeGlobal, 4);
  check(DEVICE, kAudioDevicePropertyRelatedDevices, kAudioObjectPropertyScopeGlobal, 4);
  check(DEVICE, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, 0);
  check(DEVICE, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 8);
  for (unsigned o = INPUT; o <= OUTPUT; ++o) {
    const AudioObjectPropertySelector stream_scalars[] = {
        kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
        kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
        kAudioStreamPropertyLatency};
    for (unsigned i = 0; i < sizeof(stream_scalars) / sizeof(stream_scalars[0]); ++i)
      check(o, stream_scalars[i], kAudioObjectPropertyScopeGlobal, 4);
    check(o, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
          sizeof(AudioStreamBasicDescription));
    check(o, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal,
          sizeof(AudioStreamBasicDescription));
    check(o, kAudioStreamPropertyAvailableVirtualFormats, kAudioObjectPropertyScopeGlobal,
          sizeof(AudioStreamRangedDescription));
    check(o, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal,
          sizeof(AudioStreamRangedDescription));
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
    check(DEVICE, kAudioDevicePropertyPreferredChannelsForStereo, scope, 8);
    check(DEVICE, kAudioDevicePropertyPreferredChannelLayout, scope,
          offsetof(AudioChannelLayout, mChannelDescriptions));
  }
  check(DEVICE, kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioValueRange));
  check(INPUT, kAudioStreamPropertyPhysicalFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamBasicDescription));
  check(OUTPUT, kAudioStreamPropertyAvailableVirtualFormats,
        kAudioObjectPropertyScopeGlobal, sizeof(AudioStreamRangedDescription));
  UInt32 actual;
#if OB_DIAGNOSTICS
  AudioObjectPropertyAddress a = {CLIENTS, kAudioObjectPropertyScopeGlobal, 0};
  Boolean writable = true;
  assert(settable(driver, DEVICE, 10, &a, &writable) == 0 && !writable);
  AudioServerPlugInCustomPropertyInfo info;
  AudioObjectPropertyAddress list = {kAudioObjectPropertyCustomPropertyInfoList,
                                     kAudioObjectPropertyScopeGlobal, 0};
  assert(get(driver, DEVICE, 10, &list, 0, NULL, sizeof(info), &actual,
             &info) == 0);
  assert(info.mSelector == CLIENTS &&
         info.mPropertyDataType ==
             kAudioServerPlugInCustomPropertyDataTypeCFString);
#else
  AudioObjectPropertyAddress removed = {'obcl', kAudioObjectPropertyScopeGlobal, 0};
  assert(!has(driver, DEVICE, 10, &removed));
  assert(get(driver, DEVICE, 10, &removed, 0, NULL, 0, &actual, NULL) ==
         kAudioHardwareUnknownPropertyError);
#endif
  AudioServerPlugInClientInfo app = {1, 123, true, CFSTR("org.openblue.app")};
  AudioServerPlugInClientInfo consumer = {2, 456, true,
                                          CFSTR("org.example.recorder")};
  assert(add_client(driver, DEVICE, &app) == 0 &&
         add_client(driver, DEVICE, &consumer) == 0);
  assert(start(driver, DEVICE, 2) == 0 && atomic_load(&running) == 1);
  assert(start(driver, DEVICE, 1) == 0 && atomic_load(&running) == 2);
#if OB_DIAGNOSTICS
  CFStringRef text = NULL;
  assert(get(driver, DEVICE, 10, &a, 0, NULL, sizeof(text), &actual, &text) ==
         0);
  assert(CFEqual(text, CFSTR("2")));
  CFRelease(text);
#endif
  latency();
  assert(stop(driver, DEVICE, 2) == 0 && atomic_load(&running) == 1);
  assert(stop(driver, DEVICE, 1) == 0 && atomic_load(&running) == 0);
  assert(remove_client(driver, DEVICE, &app) == 0 &&
         remove_client(driver, DEVICE, &consumer) == 0);
#if OB_DIAGNOSTICS
  assert(notifications == 6);
#else
  assert(notifications == 2);
#endif
  // Two distinct host clients must remain independent in either start order.
  AudioServerPlugInClientInfo second = {3, 789, true,
                                        CFSTR("org.example.browser")};
  for (unsigned reverse = 0; reverse < 2; ++reverse) {
    assert(add_client(driver, DEVICE, &app) == 0);
    assert(add_client(driver, DEVICE, &consumer) == 0);
    assert(add_client(driver, DEVICE, &second) == 0);
    UInt32 first = reverse ? 3 : 2, last = reverse ? 2 : 3;
    assert(start(driver, DEVICE, first) == 0);
    assert(start(driver, DEVICE, 1) == 0);
    assert(start(driver, DEVICE, last) == 0);
    assert(atomic_load(&running) == 3);
    assert(stop(driver, DEVICE, first) == 0);
    assert(atomic_load(&running) == 2);
    assert(stop(driver, DEVICE, last) == 0);
    assert(atomic_load(&running) == 1);
    assert(stop(driver, DEVICE, 1) == 0);
    assert(remove_client(driver, DEVICE, &app) == 0);
    assert(remove_client(driver, DEVICE, &consumer) == 0);
    assert(remove_client(driver, DEVICE, &second) == 0);
  }
  // Registration removal does not stop host I/O. A later StopIO may refer
  // to a retired registration or the host, while another recording starts.
  assert(add_client(driver, DEVICE, &consumer) == noErr);
  assert(start(driver, DEVICE, consumer.mClientID) == noErr);
  UInt64 first_seed = atomic_load(&seed);
  assert(start(driver, DEVICE, consumer.mClientID) == noErr);
  assert(atomic_load(&running) == 2 && atomic_load(&seed) == first_seed);
  assert(remove_client(driver, DEVICE, &consumer) == noErr);
  assert(atomic_load(&running) == 2);
  assert(stop(driver, DEVICE, kAudioServerPlugInHostClientID) == noErr);
  assert(atomic_load(&running) == 1);
  assert(stop(driver, DEVICE, consumer.mClientID) == noErr);
  assert(atomic_load(&running) == 0);
  for (unsigned session = 0; session < 3; ++session) {
    assert(add_client(driver, DEVICE, &consumer) == noErr);
    assert(start(driver, DEVICE, kAudioServerPlugInHostClientID) == noErr);
    assert(atomic_load(&running) == 1);
    assert(stop(driver, DEVICE, kAudioServerPlugInHostClientID) == noErr);
    assert(remove_client(driver, DEVICE, &consumer) == noErr);
    assert(atomic_load(&running) == 0);
  }
  assert(stop(driver, DEVICE, kAudioServerPlugInHostClientID) == kAudioHardwareIllegalOperationError);
  atomic_store(&running, UINT32_MAX);
  assert(start(driver, DEVICE, kAudioServerPlugInHostClientID) == kAudioHardwareIllegalOperationError);
  assert(atomic_load(&running) == UINT32_MAX);
  atomic_store(&running, 0);
  puts("PASS driver interface, client lifecycle and audio I/O");
}
