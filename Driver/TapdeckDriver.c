//  TapdeckDriver.c
//
//  Tapdeck の仮想オーディオデバイス (AudioServerPlugIn)。
//  カーネル拡張ではなく、coreaudiod にロードされるユーザー空間のプラグイン。
//
//  役割は「ループバック」。このデバイスの出力側に書き込まれた音が、
//  そのまま入力側から読める。これにより:
//
//      Tapdeck.app  ──(ミックス済みの音を再生)──▶  出力側
//                                                   │ リングバッファ
//      Zoom / OBS   ◀──(マイクとして読む)──────  入力側
//
//  という経路が成立する。アプリ単位の音声取得は Process Tap 側 (Sources/Engine)
//  が担当し、このドライバは「他アプリから見えるデバイス」を提供することに専念する。

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#pragma mark - 設定

#define kDeviceUID          "TapdeckDevice"
#define kDeviceModelUID     "TapdeckDeviceModel"
#define kDeviceName         "Tapdeck"
#define kManufacturerName   "Tapdeck"
#define kBoxUID             "TapdeckBox"

#define kChannelCount       2
#define kRingBufferFrames   16384   // ゼロタイムスタンプの周期でもある
#define kLatencyFrames      0
#define kSafetyOffsetFrames 0

// 対応サンプルレート。既定は 48000。
static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSupportedSampleRateCount (sizeof(kSupportedSampleRates) / sizeof(Float64))

#pragma mark - オブジェクトID

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,  // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#pragma mark - 状態

static pthread_mutex_t          gStateMutex     = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gRefCount       = 0;
static AudioServerPlugInHostRef gHost           = NULL;

static Float64  gSampleRate         = 48000.0;
static UInt32   gInputStreamActive  = 1;
static UInt32   gOutputStreamActive = 1;

// IO 実行中かどうか（StartIO / StopIO の入れ子を数える）
static UInt64   gIORunningCount     = 0;

// 仮想クロック
static Float64  gHostTicksPerFrame  = 0.0;
static UInt64   gAnchorHostTime     = 0;
static UInt64   gTimeStampCount     = 0;

// ループバック用リングバッファ。出力側が書き、入力側が読む。
static Float32  gRingBuffer[kRingBufferFrames * kChannelCount];

#pragma mark - 小道具

static inline void TapdeckLockState(void)   { pthread_mutex_lock(&gStateMutex); }
static inline void TapdeckUnlockState(void) { pthread_mutex_unlock(&gStateMutex); }

/// mach_absolute_time の 1 フレームあたりのティック数を求める。
static void TapdeckRecalculateHostTicksPerFrame(void)
{
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    Float64 hostClockFrequency = ((Float64)info.denom / (Float64)info.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / gSampleRate;
}

/// このドライバが扱うストリーム形式を組み立てる（Float32 インターリーブ）。
static void TapdeckFillStreamFormat(AudioStreamBasicDescription* outFormat, Float64 inSampleRate)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate       = inSampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat
                                 | kAudioFormatFlagsNativeEndian
                                 | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kChannelCount * sizeof(Float32);
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kChannelCount * sizeof(Float32);
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel   = 8 * sizeof(Float32);
}

static Boolean TapdeckIsSupportedSampleRate(Float64 inRate)
{
    for (UInt32 i = 0; i < kSupportedSampleRateCount; ++i) {
        if (kSupportedSampleRates[i] == inRate) return true;
    }
    return false;
}

#pragma mark - プロパティ: プラグインオブジェクト

static Boolean Tapdeck_PlugInHasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
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

static OSStatus Tapdeck_PlugInGetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                                  UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);            return 0;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);           return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);             return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);           return 0;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;                               return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Tapdeck_PlugInGetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                              UInt32 inQualifierDataSize,
                                              const void* inQualifierData,
                                              UInt32 inDataSize,
                                              UInt32* outDataSize,
                                              void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kManufacturerName);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            if (inDataSize < sizeof(AudioObjectID))         return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            *((AudioObjectID*)outData) =
                (CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo)
                    ? kObjectID_Device : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("");
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - プロパティ: デバイスオブジェクト

static UInt32 Tapdeck_DeviceStreamsForScope(AudioObjectPropertyScope inScope,
                                            AudioObjectID outStreams[2])
{
    switch (inScope) {
        case kAudioObjectPropertyScopeInput:
            outStreams[0] = kObjectID_Stream_Input;  return 1;
        case kAudioObjectPropertyScopeOutput:
            outStreams[0] = kObjectID_Stream_Output; return 1;
        default:
            outStreams[0] = kObjectID_Stream_Input;
            outStreams[1] = kObjectID_Stream_Output; return 2;
    }
}

static Boolean Tapdeck_DeviceHasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
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

static OSStatus Tapdeck_DeviceGetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                                  UInt32* outDataSize)
{
    AudioObjectID streams[2];
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize = Tapdeck_DeviceStreamsForScope(inAddress->mScope, streams)
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
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(kSupportedSampleRateCount * sizeof(AudioValueRange)); return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                                    + (kChannelCount * sizeof(AudioChannelDescription)));
            return 0;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Tapdeck_DeviceGetPropertyData(const AudioObjectPropertyAddress* inAddress,
                                              UInt32 inDataSize,
                                              UInt32* outDataSize,
                                              void* outData)
{
    AudioObjectID streams[2];
    UInt32 streamCount, n;

    switch (inAddress->mSelector) {
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
            *((CFStringRef*)outData) = CFSTR(kDeviceName);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kManufacturerName);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioDevicePropertyDeviceUID:
            *((CFStringRef*)outData) = CFSTR(kDeviceUID);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioDevicePropertyModelUID:
            *((CFStringRef*)outData) = CFSTR(kDeviceModelUID);
            CFRetain(*((CFStringRef*)outData));
            *outDataSize = sizeof(CFStringRef); return 0;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            streamCount = Tapdeck_DeviceStreamsForScope(inAddress->mScope, streams);
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
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioDevicePropertyClockDomain:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyDeviceIsAlive:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyDeviceIsRunning:
            TapdeckLockState();
            *((UInt32*)outData) = (gIORunningCount > 0) ? 1 : 0;
            TapdeckUnlockState();
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyLatency:
            *((UInt32*)outData) = kLatencyFrames;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertySafetyOffset:
            *((UInt32*)outData) = kSafetyOffsetFrames;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyIsHidden:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            *((UInt32*)outData) = kRingBufferFrames;
            *outDataSize = sizeof(UInt32); return 0;

        case kAudioDevicePropertyNominalSampleRate:
            TapdeckLockState();
            *((Float64*)outData) = gSampleRate;
            TapdeckUnlockState();
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
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                                   + (kChannelCount * sizeof(AudioChannelDescription)));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag         = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannelCount;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - プロパティ: ストリームオブジェクト

static Boolean Tapdeck_StreamHasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
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

static OSStatus Tapdeck_StreamGetPropertyDataSize(const AudioObjectPropertyAddress* inAddress,
                                                  UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
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

static OSStatus Tapdeck_StreamGetPropertyData(AudioObjectID inObjectID,
                                              const AudioObjectPropertyAddress* inAddress,
                                              UInt32 inDataSize,
                                              UInt32* outDataSize,
                                              void* outData)
{
    Boolean isInput = (inObjectID == kObjectID_Stream_Input);
    UInt32 n;

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return 0;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID); return 0;

        case kAudioStreamPropertyIsActive:
            TapdeckLockState();
            *((UInt32*)outData) = isInput ? gInputStreamActive : gOutputStreamActive;
            TapdeckUnlockState();
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
            TapdeckLockState();
            TapdeckFillStreamFormat((AudioStreamBasicDescription*)outData, gSampleRate);
            TapdeckUnlockState();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            n = inDataSize / sizeof(AudioStreamRangedDescription);
            if (n > kSupportedSampleRateCount) n = kSupportedSampleRateCount;
            for (UInt32 i = 0; i < n; ++i) {
                AudioStreamRangedDescription* d = &((AudioStreamRangedDescription*)outData)[i];
                TapdeckFillStreamFormat(&d->mFormat, kSupportedSampleRates[i]);
                d->mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                d->mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioStreamRangedDescription);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - ドライバインターフェース: 振り分け

static Boolean Tapdeck_HasProperty(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;
    switch (inObjectID) {
        case kObjectID_PlugIn:        return Tapdeck_PlugInHasProperty(inAddress);
        case kObjectID_Device:        return Tapdeck_DeviceHasProperty(inAddress);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return Tapdeck_StreamHasProperty(inAddress);
        default:                      return false;
    }
}

static OSStatus Tapdeck_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress* inAddress,
                                           Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    Boolean settable = false;
    if (inObjectID == kObjectID_Device) {
        settable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
    } else if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
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
                                            AudioObjectID inObjectID,
                                            pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress* inAddress,
                                            UInt32 inQualifierDataSize,
                                            const void* inQualifierData,
                                            UInt32* outDataSize)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    switch (inObjectID) {
        case kObjectID_PlugIn:        return Tapdeck_PlugInGetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Device:        return Tapdeck_DeviceGetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return Tapdeck_StreamGetPropertyDataSize(inAddress, outDataSize);
        default:                      return kAudioHardwareBadObjectError;
    }
}

static OSStatus Tapdeck_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void* inQualifierData,
                                        UInt32 inDataSize,
                                        UInt32* outDataSize,
                                        void* outData)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL)
        return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            return Tapdeck_PlugInGetPropertyData(inAddress, inQualifierDataSize, inQualifierData,
                                                 inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return Tapdeck_DeviceGetPropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return Tapdeck_StreamGetPropertyData(inObjectID, inAddress, inDataSize,
                                                 outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Tapdeck_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void* inQualifierData,
                                        UInt32 inDataSize,
                                        const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device
        && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 requested = *((const Float64*)inData);
        if (!TapdeckIsSupportedSampleRate(requested)) return kAudioHardwareIllegalOperationError;

        TapdeckLockState();
        Boolean changed = (requested != gSampleRate);
        TapdeckUnlockState();

        // サンプルレートの変更は即時には行えない。ホストに構成変更を依頼し、
        // 折り返し PerformDeviceConfigurationChange で実際に切り替える。
        if (changed && gHost != NULL) {
            gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device,
                                                    (UInt64)requested, NULL);
        }
        return 0;
    }

    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive: {
                if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 active = *((const UInt32*)inData);
                TapdeckLockState();
                if (inObjectID == kObjectID_Stream_Input) gInputStreamActive  = active;
                else                                      gOutputStreamActive = active;
                TapdeckUnlockState();
                return 0;
            }
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize != sizeof(AudioStreamBasicDescription))
                    return kAudioHardwareBadPropertySizeError;
                const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
                if (f->mFormatID != kAudioFormatLinearPCM
                    || f->mChannelsPerFrame != kChannelCount
                    || !TapdeckIsSupportedSampleRate(f->mSampleRate)) {
                    return kAudioDeviceUnsupportedFormatError;
                }
                TapdeckLockState();
                Boolean changed = (f->mSampleRate != gSampleRate);
                TapdeckUnlockState();
                if (changed && gHost != NULL) {
                    gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device,
                                                            (UInt64)f->mSampleRate, NULL);
                }
                return 0;
            }
            default: break;
        }
    }

    return kAudioHardwareUnknownPropertyError;
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
    TapdeckLockState();
    TapdeckRecalculateHostTicksPerFrame();
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    TapdeckUnlockState();
    return 0;
}

// このドライバは固定で1台のデバイスを公開するので、動的な作成/破棄は行わない。
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
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Tapdeck_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inClientInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

/// サンプルレート変更の実行。SetPropertyData から依頼した変更がここに戻ってくる。
static OSStatus Tapdeck_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                         AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction,
                                                         void* inChangeInfo)
{
    (void)inDriver; (void)inChangeInfo;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Float64 newRate = (Float64)inChangeAction;
    if (!TapdeckIsSupportedSampleRate(newRate)) return kAudioHardwareIllegalOperationError;

    TapdeckLockState();
    gSampleRate = newRate;
    TapdeckRecalculateHostTicksPerFrame();
    gTimeStampCount = 0;
    gAnchorHostTime = mach_absolute_time();
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    TapdeckUnlockState();
    return 0;
}

static OSStatus Tapdeck_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction,
                                                       void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return 0;
}

#pragma mark - ドライバインターフェース: IO

static OSStatus Tapdeck_StartIO(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inDeviceObjectID,
                                UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    TapdeckLockState();
    if (gIORunningCount == 0) {
        // 最初のクライアントが来たときだけ仮想クロックを張り直す。
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        TapdeckRecalculateHostTicksPerFrame();
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    ++gIORunningCount;
    TapdeckUnlockState();
    return 0;
}

static OSStatus Tapdeck_StopIO(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID,
                               UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    TapdeckLockState();
    if (gIORunningCount > 0) --gIORunningCount;
    TapdeckUnlockState();
    return 0;
}

/// 仮想クロック。実ハードウェアが無いので mach_absolute_time から時刻を合成する。
/// リングバッファ1周ぶん進むごとにタイムスタンプを1つ発行する。
static OSStatus Tapdeck_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID,
                                         Float64* outSampleTime,
                                         UInt64* outHostTime,
                                         UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    TapdeckLockState();
    UInt64  now                    = mach_absolute_time();
    Float64 ticksPerRingBuffer     = gHostTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 offsetToNextTimeStamp  = (Float64)(gTimeStampCount + 1) * ticksPerRingBuffer;
    UInt64  nextTimeStampHostTime  = gAnchorHostTime + (UInt64)offsetToNextTimeStamp;

    if (nextTimeStampHostTime <= now) ++gTimeStampCount;

    *outSampleTime = (Float64)(gTimeStampCount * kRingBufferFrames);
    *outHostTime   = gAnchorHostTime
                   + (UInt64)((Float64)gTimeStampCount * ticksPerRingBuffer);
    *outSeed       = 1;
    TapdeckUnlockState();
    return 0;
}

static OSStatus Tapdeck_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          Boolean* outWillDo,
                                          Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput)
                  || (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo)        *outWillDo        = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus Tapdeck_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

/// ここがループバックの本体。
/// 出力側に書かれたフレームをリングバッファへ置き、入力側はそこから読む。
static OSStatus Tapdeck_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      AudioObjectID inStreamObjectID,
                                      UInt32 inClientID,
                                      UInt32 inOperationID,
                                      UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                      void* ioMainBuffer,
                                      void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return 0;

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 start = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (start + frame) % kRingBufferFrames;
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                gRingBuffer[slot * kChannelCount + ch] = buffer[frame * kChannelCount + ch];
            }
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 start = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (start + frame) % kRingBufferFrames;
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) {
                UInt64 index = slot * kChannelCount + ch;
                buffer[frame * kChannelCount + ch] = gRingBuffer[index];
                // 読んだら消す。出力側が止まったときに古い音が延々ループするのを防ぐ。
                gRingBuffer[index] = 0.0f;
            }
        }
    }
    return 0;
}

static OSStatus Tapdeck_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
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

    TapdeckLockState();
    ++gRefCount;
    TapdeckUnlockState();
    *outInterface = gDriverRef;
    return 0;
}

static ULONG Tapdeck_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    TapdeckLockState();
    if (gRefCount < UINT32_MAX) ++gRefCount;
    ULONG result = gRefCount;
    TapdeckUnlockState();
    return result;
}

static ULONG Tapdeck_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    TapdeckLockState();
    if (gRefCount > 0) --gRefCount;
    ULONG result = gRefCount;
    TapdeckUnlockState();
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
