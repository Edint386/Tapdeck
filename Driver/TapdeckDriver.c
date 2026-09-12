//  TapdeckDriver.c
//
//  Tapdeck's virtual audio devices (an AudioServerPlugIn).
//  Not a kernel extension: this is a user-space plug-in loaded by Core Audio.
//
//  Its job is loopback. Audio written to a device's output side can be read
//  straight back from its input side.
//
//      Tapdeck.app  --(plays the finished mix)-->  output side
//                                                   | ring buffer
//      Zoom / OBS   <--(reads it as a mic)------   input side
//
//  Which devices exist is decided by the app. It hands the list over through a
//  Core Audio custom property, and no restart is needed.
//
//      /Library/Preferences/Audio/Tapdeck/Devices.plist
//
//  Why this path and not somewhere convenient:
//  the plug-in is hosted by a sandboxed process whose readable locations are
//  tightly limited. /Users/Shared is not among them, and a read there simply
//  fails with no denial in the log. /Library/Preferences/Audio is allowed.
//  Audio itself is root:_coreaudiod 775 and the Data directory under it is
//  SIP-restricted, so the installer (running as root) creates Audio/Tapdeck
//  owned by the user and the app writes there.
//
//  In practice even that turned out to be unreadable from the host process, so
//  the file is now only a record of state; the custom property is what works.

#include <CoreAudio/AudioServerPlugIn.h>
#include <os/log.h>
#include <errno.h>
#include <stdio.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>

#pragma mark - Constants

#define kManufacturerName   "Tapdeck"
#define kConfigurationPath  "/Library/Preferences/Audio/Tapdeck/Devices.plist"

/// Custom property the app uses to hand us the device list.
///
/// A file would be simpler, but the plug-in runs inside
/// com.apple.audio.Core-Audio-Driver-Service.helper, which is sandboxed so
/// tightly that it cannot read the paths an unprivileged app can write.
/// Core Audio custom properties travel through the HAL itself, so no file
/// system access is involved on either side.
#define kTapdeckProperty_DeviceList ((AudioObjectPropertySelector)'tpdv')

#define kMaxDevices         8
#define kMaxChannels        16
#define kDefaultChannels    2
#define kRingBufferFrames   16384   // also the zero-timestamp period
#define kNameLength         128

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSupportedSampleRateCount (sizeof(kSupportedSampleRates) / sizeof(Float64))

#pragma mark - Object IDs
//
//  plug-in        : 1
//  device i       : 2 + i*3
//  input stream i : 3 + i*3
//  output stream i: 4 + i*3

#define kObjectID_PlugIn        kAudioObjectPlugInObject
#define kDeviceObjectID(i)      ((AudioObjectID)(2 + (i) * 3))
#define kInputStreamObjectID(i) ((AudioObjectID)(3 + (i) * 3))
#define kOutputStreamObjectID(i)((AudioObjectID)(4 + (i) * 3))

enum { kObjectKind_None = 0, kObjectKind_Device, kObjectKind_InputStream, kObjectKind_OutputStream };

#pragma mark - State for one device

typedef struct {
    Boolean  isPublished;
    char     uid[kNameLength];
    char     name[kNameLength];
    UInt32   channelCount;

    Float64  sampleRate;
    UInt32   inputStreamActive;
    UInt32   outputStreamActive;

    UInt64   ioRunningCount;
    Float64  hostTicksPerFrame;
    UInt64   anchorHostTime;
    UInt64   timeStampCount;

    Float32  ring[kMaxChannels * kRingBufferFrames];
} TapdeckDevice;

static TapdeckDevice            gDevices[kMaxDevices];
static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gRefCount   = 0;
static AudioServerPlugInHostRef gHost       = NULL;

static dispatch_source_t        gConfigurationTimer = NULL;
static struct timespec          gLastConfigurationTime = { 0, 0 };
static off_t                    gLastConfigurationSize = -1;

/// Diagnostic logging. Standard output is unavailable inside the host process,
/// but os_log can be followed with
/// `log stream --predicate 'subsystem == "dev.kosuke.Tapdeck"'`.
static os_log_t TapdeckLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.kosuke.Tapdeck", "driver"); });
    return log;
}
#define TAPLOG(fmt, ...) os_log(TapdeckLog(), fmt, ##__VA_ARGS__)

static inline void LockState(void)   { pthread_mutex_lock(&gStateMutex); }
static inline void UnlockState(void) { pthread_mutex_unlock(&gStateMutex); }

#pragma mark - Small helpers

static void RecalculateHostTicks(TapdeckDevice* device)
{
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    Float64 hostClockFrequency = ((Float64)info.denom / (Float64)info.numer) * 1000000000.0;
    device->hostTicksPerFrame = hostClockFrequency / device->sampleRate;
}

static void FillStreamFormat(AudioStreamBasicDescription* format,
                             Float64 sampleRate, UInt32 channels)
{
    memset(format, 0, sizeof(AudioStreamBasicDescription));
    format->mSampleRate       = sampleRate;
    format->mFormatID         = kAudioFormatLinearPCM;
    format->mFormatFlags      = kAudioFormatFlagIsFloat
                              | kAudioFormatFlagsNativeEndian
                              | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket   = channels * sizeof(Float32);
    format->mFramesPerPacket  = 1;
    format->mBytesPerFrame    = channels * sizeof(Float32);
    format->mChannelsPerFrame = channels;
    format->mBitsPerChannel   = 8 * sizeof(Float32);
}

static Boolean IsSupportedSampleRate(Float64 rate)
{
    for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
        if (kSupportedSampleRates[i] == rate) return true;
    }
    return false;
}

/// Work out which device an object ID refers to, and what part of it.
static int ResolveObject(AudioObjectID objectID, UInt32* outIndex)
{
    if (objectID < 2) return kObjectKind_None;
    UInt32 index = (objectID - 2) / 3;
    if (index >= kMaxDevices || !gDevices[index].isPublished) return kObjectKind_None;
    *outIndex = index;
    switch ((objectID - 2) % 3) {
        case 0:  return kObjectKind_Device;
        case 1:  return kObjectKind_InputStream;
        default: return kObjectKind_OutputStream;
    }
}

static UInt32 PublishedDeviceIDs(AudioObjectID* out, UInt32 capacity)
{
    UInt32 count = 0;
    for (UInt32 i = 0; i < kMaxDevices && count < capacity; ++i) {
        if (gDevices[i].isPublished) out[count++] = kDeviceObjectID(i);
    }
    return count;
}

static UInt32 PublishedDeviceCount(void)
{
    UInt32 count = 0;
    for (UInt32 i = 0; i < kMaxDevices; ++i) if (gDevices[i].isPublished) ++count;
    return count;
}

#pragma mark - Reading and watching the configuration

typedef struct {
    char   uid[kNameLength];
    char   name[kNameLength];
    UInt32 channelCount;
} TapdeckDeviceSpec;

static void CopyCFString(CFStringRef string, char* buffer, size_t capacity)
{
    buffer[0] = '\0';
    if (string == NULL || CFGetTypeID(string) != CFStringGetTypeID()) return;
    CFStringGetCString(string, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
}

/// Interpret an array of device descriptions.
/// Each element is a dictionary with UID, Name and Channels.
static UInt32 ParseDeviceSpecs(CFArrayRef array, TapdeckDeviceSpec* specs, UInt32 capacity)
{
    UInt32 count = 0;
    if (array == NULL || CFGetTypeID(array) != CFArrayGetTypeID()) return 0;

    CFIndex total = CFArrayGetCount(array);
    for (CFIndex i = 0; i < total && count < capacity; ++i) {
        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(array, i);
        if (entry == NULL || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;

        TapdeckDeviceSpec spec;
        memset(&spec, 0, sizeof(spec));
        CopyCFString(CFDictionaryGetValue(entry, CFSTR("UID")), spec.uid, sizeof(spec.uid));
        CopyCFString(CFDictionaryGetValue(entry, CFSTR("Name")), spec.name, sizeof(spec.name));

        spec.channelCount = kDefaultChannels;
        CFNumberRef channels = CFDictionaryGetValue(entry, CFSTR("Channels"));
        if (channels != NULL && CFGetTypeID(channels) == CFNumberGetTypeID()) {
            int value = kDefaultChannels;
            CFNumberGetValue(channels, kCFNumberIntType, &value);
            if (value < 1) value = 1;
            if (value > kMaxChannels) value = kMaxChannels;
            spec.channelCount = (UInt32)value;
        }

        if (spec.uid[0] == '\0') continue;
        if (spec.name[0] == '\0') strlcpy(spec.name, spec.uid, sizeof(spec.name));
        specs[count++] = spec;
    }
    return count;
}

/// Fall back to a single device so something exists before the app connects.
static UInt32 DefaultDeviceSpecs(TapdeckDeviceSpec* specs)
{
    memset(&specs[0], 0, sizeof(TapdeckDeviceSpec));
    strlcpy(specs[0].uid,  "TapdeckDevice", sizeof(specs[0].uid));
    strlcpy(specs[0].name, "Tapdeck",       sizeof(specs[0].name));
    specs[0].channelCount = kDefaultChannels;
    return 1;
}

/// Read the configuration file, if this process is allowed to see it.
/// Kept as a best-effort fallback; the app normally pushes the list through
/// the custom property instead.
static UInt32 ReadConfiguration(TapdeckDeviceSpec* specs, UInt32 capacity)
{
    UInt32 count = 0;

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8*)kConfigurationPath, (CFIndex)strlen(kConfigurationPath), false);
    if (url != NULL) {
        CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
        if (stream != NULL && CFReadStreamOpen(stream)) {
            CFPropertyListRef plist = CFPropertyListCreateWithStream(
                NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);
            CFReadStreamClose(stream);
            if (plist != NULL) {
                count = ParseDeviceSpecs((CFArrayRef)plist, specs, capacity);
                CFRelease(plist);
            }
        } else {
            TAPLOG("configuration file not readable from this process");
        }
        if (stream != NULL) CFRelease(stream);
        CFRelease(url);
    }

    if (count == 0) count = DefaultDeviceSpecs(specs);
    return count;
}

/// Apply an already-parsed configuration. Returns true if anything changed.
/// The caller must hold gStateMutex.
///
/// Reading from disk deliberately happens outside this function. Touching the
/// disk while holding the lock would make the real-time IO thread wait for it,
/// and the audio would break up.
static Boolean ApplyConfigurationLocked(const TapdeckDeviceSpec* specs, UInt32 specCount)
{
    Boolean changed = false;

    // First remove devices that are no longer configured. Anything with IO
    // running is left alone to avoid pulling the rug out; it goes on the next
    // pass.
    for (UInt32 i = 0; i < kMaxDevices; ++i) {
        if (!gDevices[i].isPublished) continue;
        Boolean stillWanted = false;
        for (UInt32 s = 0; s < specCount; ++s) {
            if (strcmp(gDevices[i].uid, specs[s].uid) == 0) { stillWanted = true; break; }
        }
        if (!stillWanted && gDevices[i].ioRunningCount == 0) {
            gDevices[i].isPublished = false;
            changed = true;
        }
    }

    // Then add configured devices that are not published yet.
    for (UInt32 s = 0; s < specCount; ++s) {
        Boolean alreadyPublished = false;
        for (UInt32 i = 0; i < kMaxDevices; ++i) {
            if (gDevices[i].isPublished && strcmp(gDevices[i].uid, specs[s].uid) == 0) {
                // A rename can be applied in place.
                if (strcmp(gDevices[i].name, specs[s].name) != 0) {
                    strlcpy(gDevices[i].name, specs[s].name, sizeof(gDevices[i].name));
                    changed = true;
                }
                alreadyPublished = true;
                break;
            }
        }
        if (alreadyPublished) continue;

        for (UInt32 i = 0; i < kMaxDevices; ++i) {
            if (gDevices[i].isPublished) continue;
            TapdeckDevice* device = &gDevices[i];
            memset(device, 0, sizeof(TapdeckDevice));
            strlcpy(device->uid,  specs[s].uid,  sizeof(device->uid));
            strlcpy(device->name, specs[s].name, sizeof(device->name));
            device->channelCount       = specs[s].channelCount;
            device->sampleRate         = 48000.0;
            device->inputStreamActive  = 1;
            device->outputStreamActive = 1;
            RecalculateHostTicks(device);
            device->isPublished = true;
            changed = true;
            break;
        }
    }
    return changed;
}

static void NotifyDeviceListChanged(void)
{
    if (gHost == NULL) return;
    AudioObjectPropertyAddress addresses[2] = {
        { kAudioPlugInPropertyDeviceList,     kAudioObjectPropertyScopeGlobal,
          kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects,   kAudioObjectPropertyScopeGlobal,
          kAudioObjectPropertyElementMain },
    };
    gHost->PropertiesChanged(gHost, kObjectID_PlugIn, 2, addresses);
}

/// Notice updates to the configuration file.
///
/// This polls mtime rather than watching the vnode, because the file is
/// replaced (written then renamed) rather than modified in place. A vnode watch
/// would stay attached to the old inode and miss every change.
static UInt64 gTickCount = 0;

static void CheckConfiguration(void)
{
    ++gTickCount;
    struct stat info;
    Boolean exists = (stat(kConfigurationPath, &info) == 0);

    Boolean touched;
    if (!exists) {
        touched = (gLastConfigurationSize != -1);
        gLastConfigurationSize = -1;
    } else {
        touched = (info.st_mtimespec.tv_sec  != gLastConfigurationTime.tv_sec)
               || (info.st_mtimespec.tv_nsec != gLastConfigurationTime.tv_nsec)
               || (info.st_size              != gLastConfigurationSize);
        gLastConfigurationTime = info.st_mtimespec;
        gLastConfigurationSize = info.st_size;
    }
    if (!touched) return;

    // Read outside the lock.
    TapdeckDeviceSpec specs[kMaxDevices];
    UInt32 specCount = ReadConfiguration(specs, kMaxDevices);

    LockState();
    Boolean changed = ApplyConfigurationLocked(specs, specCount);
    UnlockState();

    TAPLOG("configuration changed: specCount=%u changed=%d", specCount, (int)changed);
    if (changed) NotifyDeviceListChanged();
}

static void StartConfigurationWatch(void)
{
    if (gConfigurationTimer != NULL) return;
    dispatch_queue_t queue = dispatch_queue_create("dev.kosuke.Tapdeck.config", NULL);
    gConfigurationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(gConfigurationTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC * 2, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gConfigurationTimer, ^{ CheckConfiguration(); });
    dispatch_resume(gConfigurationTimer);
}

#pragma mark - Properties: the plug-in object

static Boolean PlugInHasProperty(const AudioObjectPropertyAddress* address)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kTapdeckProperty_DeviceList:
            return true;
        default:
            return false;
    }
}

static OSStatus PlugInGetPropertyDataSize(const AudioObjectPropertyAddress* address,
                                          UInt32* outDataSize)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            LockState();
            *outDataSize = PublishedDeviceCount() * sizeof(AudioObjectID);
            UnlockState();
            return 0;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
        case kTapdeckProperty_DeviceList:
            *outDataSize = sizeof(CFPropertyListRef); return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

/// Build the current device list as a property list, so the app can read back
/// what the driver actually publishes.
static CFArrayRef CopyPublishedDeviceList(void)
{
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (array == NULL) return NULL;

    LockState();
    for (UInt32 i = 0; i < kMaxDevices; ++i) {
        if (!gDevices[i].isPublished) continue;
        CFStringRef uid = CFStringCreateWithCString(NULL, gDevices[i].uid, kCFStringEncodingUTF8);
        CFStringRef name = CFStringCreateWithCString(NULL, gDevices[i].name, kCFStringEncodingUTF8);
        int channels = (int)gDevices[i].channelCount;
        CFNumberRef channelCount = CFNumberCreate(NULL, kCFNumberIntType, &channels);

        const void* keys[]   = { CFSTR("UID"), CFSTR("Name"), CFSTR("Channels") };
        const void* values[] = { uid, name, channelCount };
        CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 3,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        if (entry != NULL) { CFArrayAppendValue(array, entry); CFRelease(entry); }
        if (uid != NULL) CFRelease(uid);
        if (name != NULL) CFRelease(name);
        if (channelCount != NULL) CFRelease(channelCount);
    }
    UnlockState();
    return array;
}

static OSStatus PlugInGetPropertyData(const AudioObjectPropertyAddress* address,
                                      UInt32 qualifierSize, const void* qualifier,
                                      UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kManufacturerName);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            LockState();
            UInt32 written = PublishedDeviceIDs((AudioObjectID*)outData, capacity);
            UnlockState();
            *outDataSize = written * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            if (inDataSize < sizeof(AudioObjectID))   return kAudioHardwareBadPropertySizeError;
            CFStringRef wanted = *((const CFStringRef*)qualifier);
            AudioObjectID result = kAudioObjectUnknown;

            LockState();
            for (UInt32 i = 0; i < kMaxDevices; ++i) {
                if (!gDevices[i].isPublished) continue;
                CFStringRef uid = CFStringCreateWithCString(NULL, gDevices[i].uid,
                                                            kCFStringEncodingUTF8);
                if (uid != NULL) {
                    if (CFStringCompare(wanted, uid, 0) == kCFCompareEqualTo) {
                        result = kDeviceObjectID(i);
                    }
                    CFRelease(uid);
                }
                if (result != kAudioObjectUnknown) break;
            }
            UnlockState();

            *((AudioObjectID*)outData) = result;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("");
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyCustomPropertyInfoList: {
            if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) {
                *outDataSize = 0; return 0;
            }
            AudioServerPlugInCustomPropertyInfo* info =
                (AudioServerPlugInCustomPropertyInfo*)outData;
            info->mSelector          = kTapdeckProperty_DeviceList;
            info->mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return 0;
        }

        case kTapdeckProperty_DeviceList:
            if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            *((CFPropertyListRef*)outData) = CopyPublishedDeviceList();
            *outDataSize = sizeof(CFPropertyListRef);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Properties: device objects

static UInt32 DeviceStreamsForScope(UInt32 index, AudioObjectPropertyScope scope,
                                    AudioObjectID streams[2])
{
    switch (scope) {
        case kAudioObjectPropertyScopeInput:
            streams[0] = kInputStreamObjectID(index);  return 1;
        case kAudioObjectPropertyScopeOutput:
            streams[0] = kOutputStreamObjectID(index); return 1;
        default:
            streams[0] = kInputStreamObjectID(index);
            streams[1] = kOutputStreamObjectID(index); return 2;
    }
}

static Boolean DeviceHasProperty(const AudioObjectPropertyAddress* address)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        default:
            return false;
    }
}

static OSStatus DeviceGetPropertyDataSize(UInt32 index,
                                          const AudioObjectPropertyAddress* address,
                                          UInt32* outDataSize)
{
    AudioObjectID streams[2];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize = DeviceStreamsForScope(index, address->mScope, streams)
                         * sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0; return 0;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(kSupportedSampleRateCount * sizeof(AudioValueRange)); return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            LockState();
            *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                          + (gDevices[index].channelCount * sizeof(AudioChannelDescription)));
            UnlockState();
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceGetPropertyData(UInt32 index,
                                      const AudioObjectPropertyAddress* address,
                                      UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    TapdeckDevice* device = &gDevices[index];
    AudioObjectID streams[2];
    UInt32 streamCount, n;

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioObjectPropertyName:
            LockState();
            *((CFStringRef*)outData) = CFStringCreateWithCString(NULL, device->name,
                                                                 kCFStringEncodingUTF8);
            UnlockState();
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioDevicePropertyDeviceUID:
            LockState();
            *((CFStringRef*)outData) = CFStringCreateWithCString(NULL, device->uid,
                                                                 kCFStringEncodingUTF8);
            UnlockState();
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioDevicePropertyModelUID:
            *((CFStringRef*)outData) = CFSTR("TapdeckDeviceModel");
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kManufacturerName);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            streamCount = DeviceStreamsForScope(index, address->mScope, streams);
            n = inDataSize / sizeof(AudioObjectID);
            if (n > streamCount) n = streamCount;
            for (UInt32 i = 0; i < n; ++i) ((AudioObjectID*)outData)[i] = streams[i];
            *outDataSize = n * sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyControlList:
            *outDataSize = 0; return 0;

        case kAudioDevicePropertyTransportType:
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyRelatedDevices:
            ((AudioObjectID*)outData)[0] = kDeviceObjectID(index);
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioDevicePropertyClockDomain:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyDeviceIsRunning:
            LockState();
            *((UInt32*)outData) = (device->ioRunningCount > 0) ? 1 : 0;
            UnlockState();
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            *((UInt32*)outData) = kRingBufferFrames;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyNominalSampleRate:
            LockState();
            *((Float64*)outData) = device->sampleRate;
            UnlockState();
            *outDataSize = sizeof(Float64); return 0;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            n = inDataSize / sizeof(AudioValueRange);
            if (n > kSupportedSampleRateCount) n = kSupportedSampleRateCount;
            for (UInt32 i = 0; i < n; ++i) {
                ((AudioValueRange*)outData)[i].mMinimum = kSupportedSampleRates[i];
                ((AudioValueRange*)outData)[i].mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioValueRange);
            return 0;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyPreferredChannelLayout: {
            LockState();
            UInt32 channels = device->channelCount;
            UnlockState();
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                                   + (channels * sizeof(AudioChannelDescription)));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag          = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = channels;
            for (UInt32 i = 0; i < channels; ++i) {
                layout->mChannelDescriptions[i].mChannelLabel =
                    (i == 0) ? kAudioChannelLabel_Left
                             : ((i == 1) ? kAudioChannelLabel_Right
                                         : kAudioChannelLabel_Discrete_0 + i);
            }
            *outDataSize = size;
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Properties: stream objects

static Boolean StreamHasProperty(const AudioObjectPropertyAddress* address)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus StreamGetPropertyDataSize(const AudioObjectPropertyAddress* address,
                                          UInt32* outDataSize)
{
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(kSupportedSampleRateCount
                                    * sizeof(AudioStreamRangedDescription));
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamGetPropertyData(UInt32 index, Boolean isInput,
                                      const AudioObjectPropertyAddress* address,
                                      UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    TapdeckDevice* device = &gDevices[index];
    UInt32 n;

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kDeviceObjectID(index);
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioStreamPropertyIsActive:
            LockState();
            *((UInt32*)outData) = isInput ? device->inputStreamActive : device->outputStreamActive;
            UnlockState();
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioStreamPropertyDirection:
            *((UInt32*)outData) = isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioStreamPropertyTerminalType:
            *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone
                                          : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioStreamPropertyStartingChannel:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioStreamPropertyLatency:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            LockState();
            FillStreamFormat((AudioStreamBasicDescription*)outData,
                             device->sampleRate, device->channelCount);
            UnlockState();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            n = inDataSize / sizeof(AudioStreamRangedDescription);
            if (n > kSupportedSampleRateCount) n = kSupportedSampleRateCount;
            LockState();
            for (UInt32 i = 0; i < n; ++i) {
                AudioStreamRangedDescription* d = &((AudioStreamRangedDescription*)outData)[i];
                FillStreamFormat(&d->mFormat, kSupportedSampleRates[i], device->channelCount);
                d->mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                d->mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            UnlockState();
            *outDataSize = n * sizeof(AudioStreamRangedDescription);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Driver interface: dispatch

static Boolean Tapdeck_HasProperty(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;
    if (inObjectID == kObjectID_PlugIn) return PlugInHasProperty(inAddress);

    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inObjectID, &index);
    UnlockState();

    switch (kind) {
        case kObjectKind_Device:       return DeviceHasProperty(inAddress);
        case kObjectKind_InputStream:
        case kObjectKind_OutputStream: return StreamHasProperty(inAddress);
        default:                       return false;
    }
}

static OSStatus Tapdeck_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID, pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress* inAddress,
                                           Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        *outIsSettable = (inAddress->mSelector == kTapdeckProperty_DeviceList);
        return 0;
    }

    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inObjectID, &index);
    UnlockState();

    Boolean settable = false;
    if (kind == kObjectKind_Device) {
        settable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
    } else if (kind == kObjectKind_InputStream || kind == kObjectKind_OutputStream) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                settable = true; break;
            default: break;
        }
    }
    *outIsSettable = settable;
    return 0;
}

static OSStatus Tapdeck_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inObjectID, pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress* inAddress,
                                            UInt32 inQualifierDataSize, const void* inQualifierData,
                                            UInt32* outDataSize)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (inObjectID == kObjectID_PlugIn) return PlugInGetPropertyDataSize(inAddress, outDataSize);

    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inObjectID, &index);
    UnlockState();

    switch (kind) {
        case kObjectKind_Device:       return DeviceGetPropertyDataSize(index, inAddress, outDataSize);
        case kObjectKind_InputStream:
        case kObjectKind_OutputStream: return StreamGetPropertyDataSize(inAddress, outDataSize);
        default:                       return kAudioHardwareBadObjectError;
    }
}

static OSStatus Tapdeck_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData,
                                        UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL)
        return kAudioHardwareIllegalOperationError;
    if (inObjectID == kObjectID_PlugIn) {
        return PlugInGetPropertyData(inAddress, inQualifierDataSize, inQualifierData,
                                     inDataSize, outDataSize, outData);
    }

    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inObjectID, &index);
    UnlockState();

    switch (kind) {
        case kObjectKind_Device:
            return DeviceGetPropertyData(index, inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_InputStream:
            return StreamGetPropertyData(index, true, inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_OutputStream:
            return StreamGetPropertyData(index, false, inAddress, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Tapdeck_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData,
                                        UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    // The app pushes the device list here. This is the primary configuration
    // path; the file on disk is only a fallback for the initial load.
    if (inObjectID == kObjectID_PlugIn) {
        if (inAddress->mSelector != kTapdeckProperty_DeviceList) {
            return kAudioHardwareUnknownPropertyError;
        }
        if (inDataSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;

        CFArrayRef array = (CFArrayRef)(*((const CFPropertyListRef*)inData));
        TapdeckDeviceSpec specs[kMaxDevices];
        UInt32 specCount = ParseDeviceSpecs(array, specs, kMaxDevices);
        if (specCount == 0) specCount = DefaultDeviceSpecs(specs);

        LockState();
        Boolean changed = ApplyConfigurationLocked(specs, specCount);
        UnlockState();

        TAPLOG("device list set by app: %u requested, changed=%d", specCount, (int)changed);
        if (changed) NotifyDeviceListChanged();
        return 0;
    }

    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inObjectID, &index);
    UnlockState();
    if (kind == kObjectKind_None) return kAudioHardwareBadObjectError;

    Float64 requested = 0;
    Boolean wantsRateChange = false;

    if (kind == kObjectKind_Device
        && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        requested = *((const Float64*)inData);
        wantsRateChange = true;
    } else if (kind == kObjectKind_InputStream || kind == kObjectKind_OutputStream) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive: {
                if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 active = *((const UInt32*)inData);
                LockState();
                if (kind == kObjectKind_InputStream) gDevices[index].inputStreamActive  = active;
                else                                 gDevices[index].outputStreamActive = active;
                UnlockState();
                return 0;
            }
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize != sizeof(AudioStreamBasicDescription))
                    return kAudioHardwareBadPropertySizeError;
                const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
                LockState();
                UInt32 channels = gDevices[index].channelCount;
                UnlockState();
                if (f->mFormatID != kAudioFormatLinearPCM
                    || f->mChannelsPerFrame != channels
                    || !IsSupportedSampleRate(f->mSampleRate)) {
                    return kAudioDeviceUnsupportedFormatError;
                }
                requested = f->mSampleRate;
                wantsRateChange = true;
                break;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    } else {
        return kAudioHardwareUnknownPropertyError;
    }

    if (!wantsRateChange) return kAudioHardwareUnknownPropertyError;
    if (!IsSupportedSampleRate(requested)) return kAudioHardwareIllegalOperationError;

    LockState();
    Boolean changed = (requested != gDevices[index].sampleRate);
    UnlockState();

    // A sample rate change cannot happen inline. Ask the host for a
    // configuration change and do the work in PerformDeviceConfigurationChange.
    if (changed && gHost != NULL) {
        gHost->RequestDeviceConfigurationChange(gHost, kDeviceObjectID(index),
                                                (UInt64)requested, NULL);
    }
    return 0;
}

#pragma mark - Driver interface: lifecycle

static HRESULT Tapdeck_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG   Tapdeck_AddRef(void* inDriver);
static ULONG   Tapdeck_Release(void* inDriver);

static OSStatus Tapdeck_Initialize(AudioServerPlugInDriverRef inDriver,
                                   AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;

    TapdeckDeviceSpec specs[kMaxDevices];
    UInt32 specCount = ReadConfiguration(specs, kMaxDevices);

    LockState();
    memset(gDevices, 0, sizeof(gDevices));
    ApplyConfigurationLocked(specs, specCount);
    UnlockState();

    TAPLOG("initialised with %u device(s) published", PublishedDeviceCount());

    // From here on, poll the file for changes as a fallback path.
    StartConfigurationWatch();
    TAPLOG("polling started: timer=%s", gConfigurationTimer ? "yes" : "no");
    return 0;
}

// The published devices come from the app, not from the HAL, so dynamic
// creation is refused.
static OSStatus Tapdeck_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                     CFDictionaryRef inDescription,
                                     const AudioServerPlugInClientInfo* inClientInfo,
                                     AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Tapdeck_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Tapdeck_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inClientInfo;
    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inDeviceObjectID, &index);
    UnlockState();
    return (kind == kObjectKind_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Tapdeck_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inClientInfo;
    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inDeviceObjectID, &index);
    UnlockState();
    return (kind == kObjectKind_Device) ? 0 : kAudioHardwareBadObjectError;
}

/// Carry out a sample rate change requested from SetPropertyData.
static OSStatus Tapdeck_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                         AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction,
                                                         void* inChangeInfo)
{
    (void)inDriver; (void)inChangeInfo;
    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) { UnlockState(); return kAudioHardwareBadObjectError; }

    Float64 newRate = (Float64)inChangeAction;
    if (!IsSupportedSampleRate(newRate)) { UnlockState(); return kAudioHardwareIllegalOperationError; }

    TapdeckDevice* device = &gDevices[index];
    device->sampleRate = newRate;
    RecalculateHostTicks(device);
    device->timeStampCount = 0;
    device->anchorHostTime = mach_absolute_time();
    memset(device->ring, 0, sizeof(device->ring));
    UnlockState();
    return 0;
}

static OSStatus Tapdeck_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return 0;
}

#pragma mark - Driver interface: IO

static OSStatus Tapdeck_StartIO(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) { UnlockState(); return kAudioHardwareBadObjectError; }

    TapdeckDevice* device = &gDevices[index];
    if (device->ioRunningCount == 0) {
        // Re-anchor the virtual clock only for the first client.
        memset(device->ring, 0, sizeof(device->ring));
        RecalculateHostTicks(device);
        device->timeStampCount = 0;
        device->anchorHostTime = mach_absolute_time();
    }
    ++device->ioRunningCount;
    UnlockState();
    return 0;
}

static OSStatus Tapdeck_StopIO(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    UInt32 index = 0;
    LockState();
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) { UnlockState(); return kAudioHardwareBadObjectError; }
    if (gDevices[index].ioRunningCount > 0) --gDevices[index].ioRunningCount;
    UnlockState();
    return 0;
}

/// The virtual clock. There is no real hardware, so it is synthesised from
/// mach_absolute_time, issuing one timestamp per trip around the ring buffer.
static OSStatus Tapdeck_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         Float64* outSampleTime, UInt64* outHostTime,
                                         UInt64* outSeed)
{
    // Called every cycle from the real-time thread. No locking here.
    (void)inDriver; (void)inClientID;
    UInt32 index = 0;
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) return kAudioHardwareBadObjectError;

    TapdeckDevice* device = &gDevices[index];
    UInt64  now                   = mach_absolute_time();
    Float64 ticksPerRingBuffer    = device->hostTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 offsetToNextTimeStamp = (Float64)(device->timeStampCount + 1) * ticksPerRingBuffer;
    UInt64  nextTimeStampHostTime = device->anchorHostTime + (UInt64)offsetToNextTimeStamp;

    if (nextTimeStampHostTime <= now) ++device->timeStampCount;

    *outSampleTime = (Float64)(device->timeStampCount * kRingBufferFrames);
    *outHostTime   = device->anchorHostTime
                   + (UInt64)((Float64)device->timeStampCount * ticksPerRingBuffer);
    *outSeed       = 1;
    return 0;
}

static OSStatus Tapdeck_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                          UInt32 inOperationID, Boolean* outWillDo,
                                          Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inClientID;
    UInt32 index = 0;
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) return kAudioHardwareBadObjectError;

    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput)
                  || (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo)        *outWillDo        = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus Tapdeck_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    UInt32 index = 0;
    int kind = ResolveObject(inDeviceObjectID, &index);
    return (kind == kObjectKind_Device) ? 0 : kAudioHardwareBadObjectError;
}

/// The loopback itself.
/// Frames written to the output side land in the ring buffer, and the input
/// side reads them back out.
static OSStatus Tapdeck_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      AudioObjectID inStreamObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                      void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return 0;

    // Real-time thread: no locking. A published device with IO running is
    // never removed by a configuration change, so channelCount and the ring
    // buffer cannot move underneath us here.
    UInt32 index = 0;
    int kind = ResolveObject(inDeviceObjectID, &index);
    if (kind != kObjectKind_Device) return kAudioHardwareBadObjectError;

    TapdeckDevice* device = &gDevices[index];
    UInt32 channels = device->channelCount;
    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 start = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (start + frame) % kRingBufferFrames;
            for (UInt32 ch = 0; ch < channels; ++ch) {
                device->ring[slot * channels + ch] = buffer[frame * channels + ch];
            }
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 start = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (start + frame) % kRingBufferFrames;
            for (UInt32 ch = 0; ch < channels; ++ch) {
                UInt64 offset = slot * channels + ch;
                buffer[frame * channels + ch] = device->ring[offset];
                // Clear on read, so stale audio does not loop once the output
                // side stops.
                device->ring[offset] = 0.0f;
            }
        }
    }
    return 0;
}

static OSStatus Tapdeck_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    UInt32 index = 0;
    int kind = ResolveObject(inDeviceObjectID, &index);
    return (kind == kObjectKind_Device) ? 0 : kAudioHardwareBadObjectError;
}

#pragma mark - Interface table and factory

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Tapdeck_QueryInterface,
    Tapdeck_AddRef,
    Tapdeck_Release,
    Tapdeck_Initialize,
    Tapdeck_CreateDevice,
    Tapdeck_DestroyDevice,
    Tapdeck_AddDeviceClient,
    Tapdeck_RemoveDeviceClient,
    Tapdeck_PerformDeviceConfigurationChange,
    Tapdeck_AbortDeviceConfigurationChange,
    Tapdeck_HasProperty,
    Tapdeck_IsPropertySettable,
    Tapdeck_GetPropertyDataSize,
    Tapdeck_GetPropertyData,
    Tapdeck_SetPropertyData,
    Tapdeck_StartIO,
    Tapdeck_StopIO,
    Tapdeck_GetZeroTimeStamp,
    Tapdeck_WillDoIOOperation,
    Tapdeck_BeginIOOperation,
    Tapdeck_DoIOOperation,
    Tapdeck_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;

static HRESULT Tapdeck_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean matches = CFEqual(requested, IUnknownUUID)
                   || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!matches) return E_NOINTERFACE;

    LockState();
    ++gRefCount;
    UnlockState();
    *outInterface = gDriverRef;
    return 0;
}

static ULONG Tapdeck_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    LockState();
    if (gRefCount < UINT32_MAX) ++gRefCount;
    ULONG result = gRefCount;
    UnlockState();
    return result;
}

static ULONG Tapdeck_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    LockState();
    if (gRefCount > 0) --gRefCount;
    ULONG result = gRefCount;
    UnlockState();
    return result;
}

/// CFPlugIn entry point, referenced by name from CFPlugInFactories in
/// Info.plist.
void* TapdeckDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* TapdeckDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}
