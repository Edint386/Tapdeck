//  TapdeckDriver.c
//
//  Tapdeck の仮想オーディオデバイス (AudioServerPlugIn)。
//  カーネル拡張ではなく、coreaudiod にロードされるユーザー空間のプラグイン。
//
//  役割は「ループバック」。デバイスの出力側に書き込まれた音が、そのまま
//  入力側から読める。
//
//      Tapdeck.app  ──(ミックス済みの音を再生)──▶  出力側
//                                                   │ リングバッファ
//      Zoom / OBS   ◀──(マイクとして読む)──────  入力側
//
//  公開するデバイスは設定ファイルで決まる。アプリが書き、ドライバが監視して
//  増減を反映する（coreaudiod の再起動は不要）。
//
//      /Library/Preferences/Audio/Tapdeck/Devices.plist
//
//  この場所でなければならない理由:
//  coreaudiod はサンドボックス下で動き、読み書きできる場所が
//  /System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb で
//  限定されている。/Users/Shared は許可リストに無く、読もうとしても
//  失敗するだけで拒否ログすら残らない。
//  /Library/Preferences/Audio 配下は読み書き both が許可されている。
//  ただし Audio 自体は root:_coreaudiod の 775、その下の Data は SIP の
//  restricted でアプリからは書けない。そこでインストーラ（root）が
//  Audio/Tapdeck をユーザー所有で作り、そこへアプリが書く。

#include <CoreAudio/AudioServerPlugIn.h>
#include <os/log.h>
#include <errno.h>
#include <stdio.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>

#pragma mark - 定数

#define kManufacturerName   "Tapdeck"
#define kConfigurationPath  "/Library/Preferences/Audio/Tapdeck/Devices.plist"

#define kMaxDevices         8
#define kMaxChannels        16
#define kDefaultChannels    2
#define kRingBufferFrames   16384   // ゼロタイムスタンプの周期でもある
#define kNameLength         128

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSupportedSampleRateCount (sizeof(kSupportedSampleRates) / sizeof(Float64))

#pragma mark - オブジェクトID
//
//  プラグイン       : 1
//  デバイス i       : 2 + i*3
//  入力ストリーム i : 3 + i*3
//  出力ストリーム i : 4 + i*3

#define kObjectID_PlugIn        kAudioObjectPlugInObject
#define kDeviceObjectID(i)      ((AudioObjectID)(2 + (i) * 3))
#define kInputStreamObjectID(i) ((AudioObjectID)(3 + (i) * 3))
#define kOutputStreamObjectID(i)((AudioObjectID)(4 + (i) * 3))

enum { kObjectKind_None = 0, kObjectKind_Device, kObjectKind_InputStream, kObjectKind_OutputStream };

#pragma mark - デバイス1台ぶんの状態

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

/// 診断用のログ。coreaudiod の中で動くので標準出力は使えない。
/// os_log なら `log stream --predicate 'subsystem == "dev.kosuke.Tapdeck"'` で追える。
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

#pragma mark - 小道具

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

/// オブジェクトIDから、どのデバイスの何かを割り出す。
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

#pragma mark - 設定ファイルの読み込みと監視

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

/// 設定ファイルを読む。無ければ既定の1台を返す（初回インストール直後など）。
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
                if (CFGetTypeID(plist) == CFArrayGetTypeID()) {
                    CFArrayRef array = (CFArrayRef)plist;
                    CFIndex total = CFArrayGetCount(array);
                    for (CFIndex i = 0; i < total && count < capacity; ++i) {
                        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(array, i);
                        if (entry == NULL || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;

                        TapdeckDeviceSpec spec;
                        memset(&spec, 0, sizeof(spec));
                        CopyCFString(CFDictionaryGetValue(entry, CFSTR("UID")),
                                     spec.uid, sizeof(spec.uid));
                        CopyCFString(CFDictionaryGetValue(entry, CFSTR("Name")),
                                     spec.name, sizeof(spec.name));

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
                        if (spec.name[0] == '\0') {
                            strlcpy(spec.name, spec.uid, sizeof(spec.name));
                        }
                        specs[count++] = spec;
                    }
                }
                CFRelease(plist);
            }
        }
        if (stream != NULL) CFRelease(stream);
        CFRelease(url);
    }

    if (count == 0) {
        // 設定が無いときの既定。v0.1 と同じ1台。
        memset(&specs[0], 0, sizeof(TapdeckDeviceSpec));
        strlcpy(specs[0].uid,  "TapdeckDevice", sizeof(specs[0].uid));
        strlcpy(specs[0].name, "Tapdeck",       sizeof(specs[0].name));
        specs[0].channelCount = kDefaultChannels;
        count = 1;
    }
    return count;
}

/// 読み込み済みの設定を現在の状態へ反映する。変化があれば true。
/// 呼び出し側で gStateMutex を保持していること。
///
/// ファイル読み込みはここには含めない。ロックを保持したままディスクを触ると、
/// 実時間のIOスレッドがその完了を待つことになり、音が途切れる。
static Boolean ApplyConfigurationLocked(const TapdeckDeviceSpec* specs, UInt32 specCount)
{
    Boolean changed = false;

    // まず、設定から消えたデバイスを外す。
    // IO 実行中のものは巻き込み事故を避けるため残す（次回の巡回で外れる）。
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

    // 次に、設定にあって未公開のものを足す。
    for (UInt32 s = 0; s < specCount; ++s) {
        Boolean alreadyPublished = false;
        for (UInt32 i = 0; i < kMaxDevices; ++i) {
            if (gDevices[i].isPublished && strcmp(gDevices[i].uid, specs[s].uid) == 0) {
                // 名前だけ変わった場合はその場で更新する。
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

/// 設定ファイルの更新を拾う。
///
/// vnode 監視ではなく mtime の巡回にしているのは、設定ファイルが上書きではなく
/// 差し替え（新規作成 → rename）で更新されるため。vnode 監視は古い inode に
/// 張り付いたままになり、変更を取りこぼす。
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

    // 読み込みはロックの外で行う。
    TapdeckDeviceSpec specs[kMaxDevices];
    UInt32 specCount = ReadConfiguration(specs, kMaxDevices);

    LockState();
    Boolean changed = ApplyConfigurationLocked(specs, specCount);
    UnlockState();

    TAPLOG("設定が更新された: specCount=%u changed=%d", specCount, (int)changed);
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

#pragma mark - プロパティ: プラグインオブジェクト

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
            *outDataSize = 0; return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
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

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0; return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - プロパティ: デバイスオブジェクト

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

#pragma mark - プロパティ: ストリームオブジェクト

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

#pragma mark - ドライバインターフェース: 振り分け

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

    // サンプルレートの変更は即時には行えない。ホストに構成変更を依頼し、
    // 折り返し PerformDeviceConfigurationChange で実際に切り替える。
    if (changed && gHost != NULL) {
        gHost->RequestDeviceConfigurationChange(gHost, kDeviceObjectID(index),
                                                (UInt64)requested, NULL);
    }
    return 0;
}

#pragma mark - ドライバインターフェース: ライフサイクル

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

    TAPLOG("Initialize 完了: 公開 %u 台", PublishedDeviceCount());

    // 以後は設定ファイルの更新を巡回で拾い、デバイスを増減させる。
    StartConfigurationWatch();
    TAPLOG("巡回を開始: timer=%s", gConfigurationTimer ? "あり" : "なし");
    return 0;
}

// 公開するデバイスは設定ファイルで決まる。HAL からの動的な作成は受けない。
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

/// サンプルレート変更の実行。SetPropertyData から依頼した変更がここに戻ってくる。
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

#pragma mark - ドライバインターフェース: IO

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
        // 最初のクライアントが来たときだけ仮想クロックを張り直す。
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

/// 仮想クロック。実ハードウェアが無いので mach_absolute_time から合成する。
/// リングバッファ1周ぶん進むごとにタイムスタンプを1つ発行する。
static OSStatus Tapdeck_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         Float64* outSampleTime, UInt64* outHostTime,
                                         UInt64* outSeed)
{
    // 実時間スレッドから毎周期呼ばれる。ロックは取らない。
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

/// ここがループバックの本体。
/// 出力側に書かれたフレームをリングバッファへ置き、入力側はそこから読む。
static OSStatus Tapdeck_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      AudioObjectID inStreamObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                      void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return 0;

    // ここは実時間スレッド。ロックは取らない。
    // 公開中かつ IO 実行中のデバイスは設定変更で外されないようにしてあるので、
    // channelCount とリングバッファはこの区間で変化しない。
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
                // 読んだら消す。出力側が止まったときに古い音がループするのを防ぐ。
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

#pragma mark - インターフェーステーブルとファクトリ

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

/// CFPlugIn のエントリポイント。Info.plist の CFPlugInFactories から名前で参照される。
void* TapdeckDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* TapdeckDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}
