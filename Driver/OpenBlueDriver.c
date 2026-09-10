// Host contracts follow Apple's AudioServerPlugIn.h and NullAudio sample.
// Audio transport is standard HAL I/O; no client HAL API or external service.
#include "OBLoopback.h"
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

enum { PLUGIN = 1, DEVICE = 2, INPUT = 3, OUTPUT = 4, CLIENTS = 'obcl' };
#define DEVICE_UID "org.openblue.virtual-device"
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interface_ptr = &interface;
static AudioServerPlugInDriverRef driver = &interface_ptr;
static AudioServerPlugInHostRef host;
static _Atomic uint32_t references = 1;
static pthread_mutex_t state = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t anchor, seed;
static double ticks_per_frame;
static _Atomic uint32_t running, consumers;
static _Atomic bool input_active = true, output_active = true;
static OBLoopback loop;
typedef struct Client {
  UInt32 id;
  bool writer, active;
  struct Client *next;
} Client;
static Client *clients;

static bool valid(AudioServerPlugInDriverRef d) { return d == driver; }
static bool object(AudioObjectID o) { return o >= PLUGIN && o <= OUTPUT; }
static AudioStreamBasicDescription format(void) {
  return (AudioStreamBasicDescription){48000,
                                       kAudioFormatLinearPCM,
                                       kAudioFormatFlagIsFloat |
                                           kAudioFormatFlagIsPacked |
                                           kAudioFormatFlagsNativeEndian,
                                       8,
                                       1,
                                       8,
                                       2,
                                       32,
                                       0};
}
static OSStatus copy_value(const void *value, UInt32 size, UInt32 capacity,
                           UInt32 *actual, void *out, bool read) {
  *actual = size;
  if (!read)
    return noErr;
  if (capacity < size)
    return kAudioHardwareBadPropertySizeError;
  if (size && !out)
    return kAudioHardwareIllegalOperationError;
  if (size)
    memcpy(out, value, size);
  return noErr;
}

// One dispatcher is the authority for HasProperty, size, and read contracts.
static OSStatus property(AudioObjectID o, const AudioObjectPropertyAddress *a,
                         UInt32 qs, const void *q, UInt32 capacity,
                         UInt32 *actual, void *out, bool read) {
  if (!object(o))
    return kAudioHardwareBadObjectError;
  if (!a || !actual)
    return kAudioHardwareIllegalOperationError;
  if (a->mElement != kAudioObjectPropertyElementMain)
    return kAudioHardwareUnknownPropertyError;
  bool global = a->mScope == kAudioObjectPropertyScopeGlobal;
  bool ins = a->mScope == kAudioObjectPropertyScopeInput;
  bool outs = a->mScope == kAudioObjectPropertyScopeOutput;
  if (!global && !(o == DEVICE && (ins || outs)))
    return kAudioHardwareUnknownPropertyError;
  UInt32 u = 0;
  Float64 rate = 48000;
  CFStringRef str = NULL;
  AudioObjectID ids[2];
  UInt32 count = 0;
  AudioStreamBasicDescription f = format();
  switch (a->mSelector) {
  case kAudioObjectPropertyBaseClass:
    u = kAudioObjectClassID;
    break;
  case kAudioObjectPropertyClass:
    u = o == PLUGIN   ? kAudioPlugInClassID
        : o == DEVICE ? kAudioDeviceClassID
                      : kAudioStreamClassID;
    break;
  case kAudioObjectPropertyOwner:
    u = o == PLUGIN ? kAudioObjectUnknown : o == DEVICE ? PLUGIN : DEVICE;
    break;
  case kAudioObjectPropertyManufacturer:
    str = CFSTR("OpenBlue");
    goto string_value;
  case kAudioObjectPropertyName:
    str = o == INPUT    ? CFSTR("OpenBlue Input")
          : o == OUTPUT ? CFSTR("OpenBlue Feed")
                        : CFSTR("OpenBlue");
    goto string_value;
  case kAudioObjectPropertyOwnedObjects:
    if (o == PLUGIN) {
      ids[0] = DEVICE;
      count = 1;
    }
    if (o == DEVICE) {
      if (!outs)
        ids[count++] = INPUT;
      if (!ins)
        ids[count++] = OUTPUT;
    }
    goto object_list;
  default:
    goto specific;
  }
  return copy_value(&u, sizeof(u), capacity, actual, out, read);
string_value:
  if (read && capacity >= sizeof(str) && out)
    CFRetain(str);
  return copy_value(&str, sizeof(str), capacity, actual, out, read);
object_list:
  // Object arrays may be read into a smaller array per the HAL contract.
  *actual = count * sizeof(AudioObjectID);
  if (!read)
    return noErr;
  count = capacity / sizeof(AudioObjectID) < count
              ? capacity / sizeof(AudioObjectID)
              : count;
  return copy_value(ids, count * sizeof(AudioObjectID), capacity, actual, out,
                    true);
specific:
  if (o == PLUGIN) {
    switch (a->mSelector) {
    case kAudioPlugInPropertyBundleID:
      str = CFSTR("org.openblue.driver");
      goto string_value;
    case kAudioPlugInPropertyDeviceList:
      ids[0] = DEVICE;
      count = 1;
      goto object_list;
    case kAudioPlugInPropertyBoxList:
      count = 0;
      goto object_list;
    case kAudioPlugInPropertyResourceBundle:
      str = CFSTR("");
      goto string_value;
    case kAudioPlugInPropertyTranslateUIDToDevice:
      if (read) {
        if (qs != sizeof(CFStringRef) || !q)
          return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(CFStringRef const *)q;
        u = uid && CFEqual(uid, CFSTR(DEVICE_UID)) ? DEVICE
                                                   : kAudioObjectUnknown;
      }
      break;
    default:
      return kAudioHardwareUnknownPropertyError;
    }
  } else if (o == DEVICE) {
    switch (a->mSelector) {
    case kAudioDevicePropertyDeviceUID:
      str = CFSTR(DEVICE_UID);
      goto string_value;
    case kAudioDevicePropertyModelUID:
      str = CFSTR("org.openblue.virtual-model");
      goto string_value;
    case kAudioDevicePropertyTransportType:
      u = kAudioDeviceTransportTypeVirtual;
      break;
    case kAudioDevicePropertyRelatedDevices:
      ids[0] = DEVICE;
      count = 1;
      goto object_list;
    case kAudioDevicePropertyClockDomain:
      u = 0;
      break;
    case kAudioDevicePropertyDeviceIsAlive:
      u = 1;
      break;
    case kAudioDevicePropertyDeviceIsRunning:
      u = atomic_load(&running) > 0;
      break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
      u = ins;
      break;
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
      u = 0;
      break;
    case kAudioDevicePropertyIsHidden:
      u = 0;
      break;
    case kAudioDevicePropertyLatency:
      u = ins ? OB_LOOP_DELAY : 0;
      break;
    case kAudioDevicePropertySafetyOffset:
      u = 0;
      break;
    case kAudioDevicePropertyZeroTimeStampPeriod:
      u = 128;
      break;
    case kAudioDevicePropertyStreams:
      if (!outs)
        ids[count++] = INPUT;
      if (!ins)
        ids[count++] = OUTPUT;
      goto object_list;
    case kAudioObjectPropertyControlList:
      count = 0;
      goto object_list;
    case kAudioDevicePropertyNominalSampleRate:
      return copy_value(&rate, sizeof(rate), capacity, actual, out, read);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
      AudioValueRange range = {48000, 48000};
      return copy_value(&range, sizeof(range), capacity, actual, out, read);
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
      UInt32 channels[2] = {1, 2};
      return copy_value(channels, sizeof(channels), capacity, actual, out,
                        read);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
      struct {
        AudioChannelLayoutTag tag;
        AudioChannelBitmap bitmap;
        UInt32 descriptions;
      } layout = {kAudioChannelLayoutTag_Stereo, 0, 0};
      return copy_value(&layout, sizeof(layout), capacity, actual, out, read);
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
      AudioServerPlugInCustomPropertyInfo info = {
          CLIENTS, kAudioServerPlugInCustomPropertyDataTypeCFString,
          kAudioServerPlugInCustomPropertyDataTypeNone};
      return copy_value(&info, sizeof(info), capacity, actual, out, read);
    }
    case CLIENTS: {
      if (!global)
        return kAudioHardwareUnknownPropertyError;
      *actual = sizeof(CFStringRef);
      if (!read)
        return noErr;
      if (capacity < sizeof(CFStringRef) || !out)
        return kAudioHardwareBadPropertySizeError;
      CFStringRef value = CFStringCreateWithFormat(NULL, NULL, CFSTR("%u"),
                                                   atomic_load(&consumers));
      if (!value)
        return kAudioHardwareUnspecifiedError;
      *(CFStringRef *)out = value;
      return noErr;
    }
    default:
      return kAudioHardwareUnknownPropertyError;
    }
  } else {
    switch (a->mSelector) {
    case kAudioStreamPropertyIsActive:
      u = atomic_load(o == INPUT ? &input_active : &output_active);
      break;
    case kAudioStreamPropertyDirection:
      u = o == INPUT;
      break;
    case kAudioStreamPropertyTerminalType:
      u = o == INPUT ? kAudioStreamTerminalTypeMicrophone
                     : kAudioStreamTerminalTypeLine;
      break;
    case kAudioStreamPropertyStartingChannel:
      u = 1;
      break;
    case kAudioStreamPropertyLatency:
      u = 0;
      break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
      return copy_value(&f, sizeof(f), capacity, actual, out, read);
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
      AudioStreamRangedDescription range = {f, {48000, 48000}};
      return copy_value(&range, sizeof(range), capacity, actual, out, read);
    }
    default:
      return kAudioHardwareUnknownPropertyError;
    }
  }
  return copy_value(&u, sizeof(u), capacity, actual, out, read);
}

static HRESULT query(void *d, REFIID iid, LPVOID *out) {
  if (d != driver || !out)
    return E_NOINTERFACE;
  *out = NULL;
  CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
  bool ok = CFEqual(uuid, IUnknownUUID) ||
            CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
  CFRelease(uuid);
  if (!ok)
    return E_NOINTERFACE;
  atomic_fetch_add(&references, 1);
  *out = driver;
  return S_OK;
}
static ULONG addref(void *d) {
  return d == driver ? atomic_fetch_add(&references, 1) + 1 : 0;
}
static ULONG release(void *d) {
  return d == driver ? atomic_fetch_sub(&references, 1) - 1 : 0;
}
static OSStatus initialize(AudioServerPlugInDriverRef d,
                           AudioServerPlugInHostRef h) {
  if (!valid(d))
    return kAudioHardwareBadObjectError;
  host = h;
  mach_timebase_info_data_t t;
  mach_timebase_info(&t);
  ticks_per_frame = (1e9 * (double)t.denom / t.numer) / 48000;
  atomic_store(&anchor, mach_absolute_time());
  return noErr;
}
static OSStatus create_device(AudioServerPlugInDriverRef d,
                              CFDictionaryRef desc,
                              const AudioServerPlugInClientInfo *c,
                              AudioObjectID *out) {
  return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroy_device(AudioServerPlugInDriverRef d, AudioObjectID o) {
  return kAudioHardwareUnsupportedOperationError;
}
static void changed(void) {
  if (host) {
    AudioObjectPropertyAddress a = {CLIENTS, kAudioObjectPropertyScopeGlobal,
                                    0};
    host->PropertiesChanged(host, DEVICE, 1, &a);
  }
}
static void running_changed(void) {
  if (host) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceIsRunning,
                                    kAudioObjectPropertyScopeGlobal, 0};
    host->PropertiesChanged(host, DEVICE, 1, &a);
  }
}
static OSStatus add_client(AudioServerPlugInDriverRef d, AudioObjectID o,
                           const AudioServerPlugInClientInfo *info) {
  if (!valid(d) || o != DEVICE || !info)
    return kAudioHardwareBadObjectError;
  Client *c = calloc(1, sizeof(*c));
  if (!c)
    return kAudioHardwareUnspecifiedError;
  c->id = info->mClientID;
  c->writer =
      info->mBundleID && CFEqual(info->mBundleID, CFSTR("org.openblue.app"));
  pthread_mutex_lock(&state);
  for (Client *p = clients; p; p = p->next)
    if (p->id == c->id) {
      pthread_mutex_unlock(&state);
      free(c);
      return kAudioHardwareIllegalOperationError;
    }
  c->next = clients;
  clients = c;
  pthread_mutex_unlock(&state);
  return noErr;
}
static OSStatus remove_client(AudioServerPlugInDriverRef d, AudioObjectID o,
                              const AudioServerPlugInClientInfo *info) {
  if (!valid(d) || o != DEVICE || !info)
    return kAudioHardwareBadObjectError;
  bool notify = false;
  pthread_mutex_lock(&state);
  bool was_running = atomic_load(&running) > 0;
  Client **link = &clients;
  while (*link) {
    Client *c = *link;
    if (c->id == info->mClientID) {
      if (c->active) {
        atomic_fetch_sub(&running, 1);
        if (!c->writer) {
          atomic_fetch_sub(&consumers, 1);
          notify = true;
        }
      }
      *link = c->next;
      free(c);
      break;
    }
    link = &c->next;
  }
  bool running_change = was_running != (atomic_load(&running) > 0);
  pthread_mutex_unlock(&state);
  if (notify)
    changed();
  if (running_change)
    running_changed();
  return noErr;
}
static OSStatus config(AudioServerPlugInDriverRef d, AudioObjectID o,
                       UInt64 action, void *info) {
  return valid(d) && o == DEVICE ? noErr : kAudioHardwareBadObjectError;
}
static Boolean has(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid,
                   const AudioObjectPropertyAddress *a) {
  UInt32 n;
  return valid(d) && property(o, a, 0, NULL, 0, &n, NULL, false) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef d, AudioObjectID o,
                         pid_t pid, const AudioObjectPropertyAddress *a,
                         Boolean *out) {
  if (!out)
    return kAudioHardwareIllegalOperationError;
  if (!has(d, o, pid, a))
    return kAudioHardwareUnknownPropertyError;
  *out = o >= INPUT && (a->mSelector == kAudioStreamPropertyIsActive ||
                        a->mSelector == kAudioStreamPropertyVirtualFormat ||
                        a->mSelector == kAudioStreamPropertyPhysicalFormat);
  return noErr;
}
static OSStatus size(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid,
                     const AudioObjectPropertyAddress *a, UInt32 qs,
                     const void *q, UInt32 *out) {
  return valid(d) ? property(o, a, qs, q, 0, out, NULL, false)
                  : kAudioHardwareBadObjectError;
}
static OSStatus get(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid,
                    const AudioObjectPropertyAddress *a, UInt32 qs,
                    const void *q, UInt32 cap, UInt32 *n, void *out) {
  return valid(d) ? property(o, a, qs, q, cap, n, out, true)
                  : kAudioHardwareBadObjectError;
}
static OSStatus set(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid,
                    const AudioObjectPropertyAddress *a, UInt32 qs,
                    const void *q, UInt32 n, const void *in) {
  Boolean can = false;
  OSStatus e = settable(d, o, pid, a, &can);
  if (e)
    return e;
  if (!can)
    return kAudioHardwareIllegalOperationError;
  if (!in)
    return kAudioHardwareIllegalOperationError;
  if (a->mSelector == kAudioStreamPropertyIsActive) {
    if (n != sizeof(UInt32))
      return kAudioHardwareBadPropertySizeError;
    atomic_store(o == INPUT ? &input_active : &output_active,
                 *(const UInt32 *)in != 0);
    if (host)
      host->PropertiesChanged(host, o, 1, a);
    return noErr;
  }
  if (n != sizeof(AudioStreamBasicDescription))
    return kAudioHardwareBadPropertySizeError;
  const AudioStreamBasicDescription *f = in;
  AudioStreamBasicDescription expected = format();
  return f->mSampleRate == expected.mSampleRate &&
                 f->mFormatID == expected.mFormatID &&
                 f->mFormatFlags == expected.mFormatFlags &&
                 f->mBytesPerPacket == 8 && f->mFramesPerPacket == 1 &&
                 f->mBytesPerFrame == 8 && f->mChannelsPerFrame == 2 &&
                 f->mBitsPerChannel == 32
             ? noErr
             : kAudioDeviceUnsupportedFormatError;
}
static OSStatus start_stop(AudioServerPlugInDriverRef d, AudioObjectID o,
                           UInt32 id, bool start) {
  if (!valid(d) || o != DEVICE)
    return kAudioHardwareBadObjectError;
  pthread_mutex_lock(&state);
  Client *c = clients;
  while (c && c->id != id)
    c = c->next;
  if (!c || c->active == start) {
    pthread_mutex_unlock(&state);
    return kAudioHardwareIllegalOperationError;
  }
  bool was_running = atomic_load(&running) > 0;
  if (start) {
    if (atomic_load(&running) == 0) {
      ob_loop_clear(&loop);
      atomic_store(&anchor, mach_absolute_time());
      atomic_fetch_add(&seed, 1);
    }
    atomic_fetch_add(&running, 1);
    if (!c->writer)
      atomic_fetch_add(&consumers, 1);
  } else {
    atomic_fetch_sub(&running, 1);
    if (!c->writer)
      atomic_fetch_sub(&consumers, 1);
  }
  c->active = start;
  bool notify = !c->writer;
  bool running_change = was_running != (atomic_load(&running) > 0);
  pthread_mutex_unlock(&state);
  if (notify)
    changed();
  if (running_change)
    running_changed();
  return noErr;
}
static OSStatus start(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
  return start_stop(d, o, c, true);
}
static OSStatus stop(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
  return start_stop(d, o, c, false);
}
static OSStatus timestamp(AudioServerPlugInDriverRef d, AudioObjectID o,
                          UInt32 c, Float64 *sample, UInt64 *time,
                          UInt64 *outseed) {
  if (!valid(d) || o != DEVICE)
    return kAudioHardwareBadObjectError;
  if (!sample || !time || !outseed)
    return kAudioHardwareIllegalOperationError;
  uint64_t a = atomic_load(&anchor), now = mach_absolute_time();
  double periods = floor((double)(now - a) / (ticks_per_frame * 128));
  *sample = periods * 128;
  *time = a + (uint64_t)(*sample * ticks_per_frame);
  *outseed = atomic_load(&seed);
  return noErr;
}
static OSStatus will(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c,
                     UInt32 op, Boolean *yes, Boolean *inplace) {
  if (!valid(d) || o != DEVICE)
    return kAudioHardwareBadObjectError;
  if (yes)
    *yes = op == kAudioServerPlugInIOOperationReadInput ||
           op == kAudioServerPlugInIOOperationWriteMix;
  if (inplace)
    *inplace = true;
  return noErr;
}
static OSStatus begin_end(AudioServerPlugInDriverRef d, AudioObjectID o,
                          UInt32 c, UInt32 op, UInt32 n,
                          const AudioServerPlugInIOCycleInfo *cycle) {
  return valid(d) && o == DEVICE ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus io(AudioServerPlugInDriverRef d, AudioObjectID o,
                   AudioObjectID stream, UInt32 c, UInt32 op, UInt32 n,
                   const AudioServerPlugInIOCycleInfo *cycle, void *buffer,
                   void *secondary) {
  if (!valid(d) || o != DEVICE)
    return kAudioHardwareBadObjectError;
  if (!cycle || !buffer || n > OB_LOOP_CAPACITY)
    return kAudioHardwareIllegalOperationError;
  if (op == kAudioServerPlugInIOOperationWriteMix) {
    if (stream != OUTPUT)
      return kAudioHardwareBadObjectError;
    if (atomic_load(&output_active))
      ob_loop_write(&loop, (int64_t)cycle->mOutputTime.mSampleTime, buffer, n);
  } else if (op == kAudioServerPlugInIOOperationReadInput) {
    if (stream != INPUT)
      return kAudioHardwareBadObjectError;
    if (atomic_load(&input_active))
      ob_loop_read(&loop, (int64_t)cycle->mInputTime.mSampleTime, buffer, n);
    else
      memset(buffer, 0, n * 8);
  }
  return noErr;
}
static AudioServerPlugInDriverInterface interface = {NULL,
                                                     query,
                                                     addref,
                                                     release,
                                                     initialize,
                                                     create_device,
                                                     destroy_device,
                                                     add_client,
                                                     remove_client,
                                                     config,
                                                     config,
                                                     has,
                                                     settable,
                                                     size,
                                                     get,
                                                     set,
                                                     start,
                                                     stop,
                                                     timestamp,
                                                     will,
                                                     begin_end,
                                                     io,
                                                     begin_end};
__attribute__((visibility("default"))) void *
OpenBlue_Create(CFAllocatorRef allocator, CFUUIDRef type) {
  return CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
