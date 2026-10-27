# Tapdeck for Windows — porting plan

A plan, not a port: no Windows code exists yet. It maps every part of Tapdeck to what Windows
offers, says what can be carried over, chooses a language and UI stack, works through the
virtual device driver and its signing, and orders the work into milestones that each end in
a result that can be checked. Work happens on the `feature/windows` branch. Facts were
checked on 2026-10-21.

Like [`platform-limits.md`](platform-limits.md), every claim carries a mark:

| Mark | Meaning |
|---|---|
| **Verified** | Measured or exercised. Nothing has run on Windows yet, so this mark appears only for the macOS behaviour the plan starts from, as recorded in the README, `platform-limits.md` and the code. |
| **Documented** | Stated by a linked primary source: Microsoft's documentation, a standards body, a vendor's own page, or the source code of a well-known project that relies on the behaviour. Not exercised here. |
| **Unknown** | Needs the test named in parentheses (W1–W39), listed under [Tests to run](#tests-to-run), or the step of the plan that answers it. |
| **Not possible** | Blocked; the reason is given. |
| **Design** | A choice this plan makes; nothing to verify yet. |

In the subsystem map, "—" marks a row that is carried over from the macOS code and checked by
the parity tests rather than by a Windows source. Each bracketed label, such as
[process-loopback-params], links to its source.

## Summary

- **Most of Tapdeck maps onto documented Windows APIs.** One app's audio comes from WASAPI
  process loopback, devices are driven through WASAPI in shared mode, a device's own volume
  through `IAudioEndpointVolume`, screen capture through Windows.Graphics.Capture, and
  encoding through Media Foundation.
- **Virtual devices are the hard part, and may not be shippable by an individual.** Both of
  Windows' audio driver models are kernel-mode, and no user-mode way to create an audio device
  is documented, so they need a kernel driver. A kernel driver loads on an ordinary PC only
  when Microsoft has signed it, Microsoft signs only for members of its hardware program, and
  the program requires an EV certificate, which is issued to registered organisations and
  businesses, not to people. Since April 2026 Windows 11 also moves towards trusting only fully
  certified (HLK-tested) drivers. The plan therefore makes Tapdeck useful without its own
  driver, checks the signing route on paper in the first week, and builds the driver late
  ([The virtual device driver](#the-virtual-device-driver)).
- **Five smaller things do not map cleanly.**
  1. *Process loopback's exclude mode leaves out only one process tree*, so "All system audio"
     cannot directly exclude the apps a mix lists separately; a sum of per-app streams might
     (W9, [All system audio](#all-system-audio)).
  2. *There is no "muted when tapped"*: replacing an app's original sound needs either muting
     its session, which one forum report suggests also silences the capture (W6), or per-app
     routing through an undocumented interface (W10, [Replacing the original
     sound](#replacing-the-original-sound)).
  3. *A shared-mode device carries at most eight channels*, against up to sixteen on
     Tapdeck's macOS virtual devices ([The virtual device driver](#the-virtual-device-driver)).
  4. *Media Foundation's MP4 sink takes one audio stream*, so one track per channel pair needs
     a muxer of Tapdeck's own unless the WinRT encoding pipeline writes several (W28,
     [Screen recording](#screen-recording)).
  5. *No capture of one app's windows*: a Windows.Graphics.Capture item is one window or one
     display, and compositing one session per window is not planned ([Screen
     recording](#screen-recording)).
- **What carries over is the signal processing.** About 1,190 lines of effects, loudness,
  gain, limiter and delay code are ported and proven against reference vectors generated from
  the unchanged Swift code; the routing graph (33 lines) is ported and checked by `graphtest`,
  and the ring buffer (216 lines) keeps its design but is rewritten lock-free ([What can be
  shared](#what-can-be-shared)).
- **Recommended stack**: a C++20 engine and harness with a C# UI (WinUI 3 provisionally; a
  short spike at the start of the app milestone decides between it and WPF), talking through a
  coarse C interface ([Language and UI stack](#language-and-ui-stack)).
- **Order of work**: a one-week platform spike on Windows and the paper signing check come
  first, the DSP port runs on the Mac at the same time, then mixing in `tapproof.exe`, then
  the app ([Milestones](#milestones)).
- **Oldest Windows**: Windows 11 version 24H2 (build 26100) and later.

## Subsystem map

| Subsystem | macOS today | Windows equivalent | Mark |
|---|---|---|---|
| One app's audio | `ProcessTap`: `CATapDescription(stereoMixdownOfProcesses:)`, a private aggregate device, an IOProc | Process loopback: `ActivateAudioInterfaceAsync` with `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`, include mode | Documented [process-loopback-params] |
| All system audio | One global tap excluding Tapdeck and every app the mix lists separately | Process loopback in exclude mode takes one process tree: Tapdeck only | Documented [process-loopback-mode]; the rest Unknown (W9) |
| Replace the original | `CATapMuteBehavior.mutedWhenTapped` | No counterpart; session mute or per-app routing | Unknown (W6, W10) |
| Device input | `DeviceInput`, an AUHAL with the input bus | WASAPI shared-mode capture, event driven | Documented [initialize] |
| Device output | `DeviceOutput`, an AUHAL render callback | WASAPI shared-mode render, event driven | Documented [initialize] |
| Device list and identity | `AudioDevice`: HAL device list, UID, transport type | `IMMDeviceEnumerator`, endpoint ID strings, `PKEY_AudioEndpoint_StableId` | Documented [endpoint-ids] [stable-id]; transport Unknown (W11); finding a device again after a driver reinstall W19 |
| Device and app changes | Lists re-read on demand (at launch, when a window or the menu bar popover opens, on Refresh); listeners only for a device's volume and mute and a tap's rate | `IMMNotificationClient` and `IAudioSessionNotification`: new behaviour, not a port | Documented [notification-client] [session-notification] |
| Application list | `AudioProcess`: the HAL's process objects, bundle ID | Audio sessions per endpoint, PID, executable path or package identity | Documented [session-manager2] [session-control2] [image-name] [get-aumid] |
| Sample rate conversion | `FormatConverter` (AVAudioConverter) | The audio engine's converter on capture streams; a resampler of Tapdeck's own for outputs | Documented [streamflags] |
| Mixer, ring buffers, fan-out | `Mixer`, `AudioRingBuffer` | Same design, re-implemented with stricter real-time rules | — |
| Effects, loudness, limiter, delay | `Effects`, `Loudness`, `GainStage`, `DelayLine` | Ported, checked against reference vectors | — |
| A device's own volume | `DeviceVolume`: `kAudioDevicePropertyVolumeScalar`, listeners | `IAudioEndpointVolume` and its callback | Documented [endpoint-volume] |
| AirPlay as the Mac's output | `MixerModel` borrows the default output | No AirPlay; no documented API sets the default device (tools use the undocumented `IPolicyConfig`) | Documented [enumerator] [soundswitch] [audiodevicecmdlets] |
| Feedback detection | `RoutingGraph` | Same algorithm, ported; render and capture endpoints paired by container ID for physical devices, from Tapdeck's driver list for its own, and by name for third-party cables | Algorithm —; pairing Documented [container-id], Unknown (W11, W26) |
| Virtual devices | `AudioServerPlugIn` in user space | A kernel-mode audio driver, signed by Microsoft | Documented [acx-overview] [driver-signing-policy] |
| Handing the device list to the driver | Custom property `'tpdv'` | A private KS property set | Documented [audio-property-requests] [ikscontrol]; for a standard user Unknown (W22) |
| Recording a mix | `MixRecorder` (AVAudioFile) | WAV and AIFF written directly; FLAC, ALAC, AAC, MP3 through Media Foundation | Documented [aac-encoder] [mp3-encoder]; FLAC and ALAC Unknown (W14) |
| Screen recording | ScreenCaptureKit, AVAssetWriter (.mov, one AAC track per pair) | Windows.Graphics.Capture, Media Foundation encoders and MP4 sink; several tracks need more | Documented [wgc] [mp4-sink-create]; one app's windows not built (Design); Unknown (W15, W16, W28, W30) |
| Menu bar item | `NSStatusItem` and a popover | A notification area icon and a flyout window | Documented [notification-area] |
| Settings and saved mixes | `UserDefaults` | JSON files under `%APPDATA%\Tapdeck`, written by the engine | Design |
| Translations and language choice | `Localizable.xcstrings`, `LocalizedStringResource` | A table generated from the same catalog plus a Windows overlay | Design |
| Permissions | TCC: audio capture, microphone, screen recording | One microphone switch for desktop apps; loopback undocumented; a screen-capture privacy setting whose effect on an unpackaged app is not stated | Documented [privacy-mic] [policy-csp-privacy]; Unknown (W8, W31) |
| Signing and installing the app | Shared self-signed certificate, dmg | A per-user installer; a code signing certificate before the first public build | Documented [smartscreen] [smart-app-control] |
| Measurement harness | `tapproof` | `tapproof.exe` with the same commands except `rate` (no documented API sets a device's shared-mode format) and, until the driver exists, `virtual`; plus a glitch counter | Design |

## Capture and devices

### Capturing one app

**Today.** `ProcessTap` describes the wanted processes with a `CATapDescription`, wraps the
tap in a private aggregate device clocked by the default output, and reads it through an
IOProc. The tap's reported rate can be wrong, so the rate is read from the aggregate, and a
listener follows rate changes mid-run (Verified on macOS).

**On Windows.** `ActivateAudioInterfaceAsync` on `VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK`
with `AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS` returns an `IAudioClient` that captures the render
streams of one process and its children (`PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE`)
— Documented [process-loopback-params] [process-loopback-mode]. Microsoft's ApplicationLoopback
sample shows the whole path [app-loopback-sample].

| Point | Status | Consequence |
|---|---|---|
| Minimum version | Documented: build 20348 [process-loopback-params]. OBS and NAudio enable it from build 19041, OBS noting that it works earlier than documented [obs-plugin-main] [naudio-builder]. | Tapdeck's floor, build 26100, clears the documented minimum. |
| One target per stream | Documented: the parameters hold a single `TargetProcessId` [process-loopback-params]. | One stream per app source, as today with one tap per source. |
| Child processes | Documented: include mode takes the whole process tree [process-loopback-mode]. | Browsers are expected to play from a child process, so the source would target the root of the tree. Unknown which PID to show and pin (W2). |
| Format | Documented: `GetMixFormat` is not implemented on this client, so the caller chooses the format [ms-qa-mixformat]; the sample passes `AUTOCONVERTPCM` [app-loopback-source]. | Tapdeck asks for float at the mix's rate and lets the audio engine convert. The macOS trap of a tap reporting the wrong rate has no counterpart, but the delivered rate is still measured (W3). |
| Silence | Documented: a target with no render streams gives the capturing process silence [app-loopback-sample]; whether packets keep flowing is not stated. For whole-device loopback, Microsoft documents that events are set for active loopback streams [initialize], and Matthew van Eerde, a Microsoft audio engineer at the time, describes no packets at all while nothing plays [vaneerde-loopback]. Unknown for both (W4). | The ring buffer returns silence on underflow. Each pause drains it and the next sound waits for a full cushion again — the same latency as at the start, but counted as an underrun, so diagnostics and the silent-source check must tell pauses from dropouts. |
| Clock | Documented: the capture is not tied to an endpoint [app-loopback-sample]. Unknown which clock paces it (W5). | Decides whether drift needs correcting ([Sample rates and clocks](#sample-rates-and-clocks)). |
| Volume | Unknown (W6). No documentation; one OBS forum user reports that muting an app in Windows' volume mixer silences application capture [obs-forum-mute]; in another thread users report that on Windows 11 whole-device capture follows the master volume depending on the output path, and one reply says OBS's per-app capture gets the audio before the Windows volume [obs-forum-volume]. | Rules out muting the app's session as a way to replace its sound, if confirmed. |
| Silent apps | Unknown (W2). A report on Microsoft's sample says the new Teams desktop app comes out as zeros, in include and in exclude streams, while whole-device loopback hears it [teams-issue]. | A source that stays silent while its session shows sound is flagged in the UI instead of failing quietly. |
| Permission | Unknown (W8). The reference says activation may show a consent prompt the first time, naming microphone access as the example, and must run on the main UI thread so the prompt can appear; it does not say whether loopback triggers one [activate-async]. | On macOS a missing usage string meant silence without an error; the Windows test looks for the same trap. |
| Ducking | Documented: when a communication stream opens on the default communication device, as in a Zoom or Teams call, Windows lowers other sounds by the amount chosen on the Communications tab of the Sound control panel [stream-attenuation]. An app can opt its own session out; the change takes effect only after the stream is stopped and started again [ducking-preference] [ducking-disable]; whether the call works on another app's session taken from the enumerator is not documented. Unknown whether the duck reaches what process loopback captures, and whether a stream tagged for communications on another device triggers it (W34, read with W6). | Tapdeck opts its own sessions out. If the captured apps are lowered in the mix, the UI says so when a call starts and points to the Communications tab. |
| The target exits | Unknown (W36): does the stream report an error, deliver silence, or stop? | macOS does not notice: the source keeps its tap, and a refresh retries only sources that never attached, so a relaunched app is picked up when the mix restarts; an app missing at the start is marked "not running" and attached once a refresh finds it (Verified in the code). Windows attaches it again as soon as a matching session appears or the process starts. |

Discontinuities are reported per packet (`AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`), with a
device position and a performance-counter time for each — Documented [capture-getbuffer].
They take the place of `ProcessTap`'s discontinuity count and measured rate.

### All system audio

**Today.** One global tap excludes Tapdeck itself, so a mix does not hear its own output, and
every app the same mix lists as a source of its own, so those are not heard twice, about
6 dB too loud. The tap is rebuilt when the list changes (Verified on macOS).

**On Windows**, three constructions:

1. **Process loopback in exclude mode with Tapdeck's PID.** Everything except Tapdeck's own
   process tree — Documented [process-loopback-mode]. This removes the feedback path, but it
   cannot also leave out other apps, because the mode takes one process. The Teams report
   above concerns exactly this mode [teams-issue], so W2 checks every listed app in an
   exclude stream as well as in its own.
2. **Whole-device loopback** (`AUDCLNT_STREAMFLAGS_LOOPBACK`) on a render endpoint —
   Documented [loopback-recording]. It includes Tapdeck's own playback to that device, so it
   only suits devices no mix plays into. Not used as a source; the harness's `glitch` reads an
   output back through it ([The measurement harness](#the-measurement-harness)).
3. **A sum of include streams.** Enumerate the audio sessions on every render endpoint, open
   one include stream per process tree except Tapdeck and the separately listed apps, and add
   streams as sessions appear (`IAudioSessionNotification`) — the building blocks are
   Documented [session-manager2] [session-notification]. Unknown (W9): the cost of twenty or
   more streams, and how much of an app's first sound is lost before its stream starts.

Subtracting a separately captured app from the global stream is Not possible in practice: the
two streams are converted and timed independently, so the subtraction would not cancel.

The plan uses construction 1 first. The UI says plainly that an app listed on its own is also
part of "All system audio" in that mix, and construction 3 replaces it once W9 passes.

### Replacing the original sound

**Today.** `mutedWhenTapped` silences the app's own output while Tapdeck plays the processed
copy, and the original returns within 1.5 s if Tapdeck is killed (Verified on macOS).

**On Windows** there is no documented counterpart. Two routes:

- **Mute the app's audio session.** Enumerating other processes' sessions is Documented
  [session-manager2]; muting them through `ISimpleAudioVolume` obtained from an enumerated
  session is how EarTrumpet does it, though the reference pages only describe a process's own
  sessions [simple-audio-volume] [eartrumpet-session]. If capture is taken after session
  volume, as the OBS report suggests, muting silences the capture too (W6), which would rule
  this route out. Session volume persists across restarts — Documented [simple-audio-volume] —
  so a crash would leave the app muted until Tapdeck's next launch undoes it.
- **Route the app to a device nobody listens to.** Windows' per-app output device (the volume
  mixer in Sound settings) is set by EarTrumpet through the undocumented
  `IAudioPolicyConfigFactory` and its `SetPersistedDefaultAudioEndpoint` [eartrumpet-policy].
  With a virtual cable or an output nobody listens to as the target, the app is silent on the
  speakers while process loopback, which is not tied to an endpoint, keeps capturing it.
  Unknown (W10): whether capture follows the app there, whether the interface still works on
  current builds, and whether the route outlives Tapdeck, as the call's name suggests, so that
  a crash would leave the app routed away. The test needs no driver of Tapdeck's own: any
  third-party cable will do, or an output that is active but not listened to, such as a
  connected display's HDMI audio; an unplugged endpoint cannot be opened at all
  [device-state].

Either way, Tapdeck's next launch undoes what a crash left behind, as `MixerModel` already does
for the borrowed AirPlay output. Because this is a headline feature resting on undocumented
interfaces, W6 and W10 run in the first week ([Milestones](#milestones)).

Windows also allows something macOS does not: another app's own volume can be changed through
the same session interface, as EarTrumpet does [eartrumpet-session], although Microsoft's
reference pages describe only a process's own sessions [simple-audio-volume]. A later version
could offer per-app volume without capturing at all; W6 checks the interface along the way.

### Device input and output

**Today.** `DeviceOutput` and `DeviceInput` drive an AUHAL each, non-interleaved Float32, all
of the device's channels, without AVAudioEngine's channel handling (Verified on macOS).

**On Windows**, each is an `IAudioClient` in shared mode with
`AUDCLNT_STREAMFLAGS_EVENTCALLBACK` — Documented [initialize]. A thread per stream waits on
the event and fills or drains the buffer, registered with MMCSS under its "Pro Audio" task
[mmcss] [mmcss-overview]. WASAPI buffers are interleaved, so each stream de-interleaves, as
`ProcessTap.normalize` does today, but into planar buffers allocated in advance (`normalize`
allocates a new buffer on every callback).

- **Formats.** Capture streams (microphones, interfaces) add `AUTOCONVERTPCM` with
  `SRC_DEFAULT_QUALITY` and arrive at the mix's rate, converted by the audio engine before any
  effect runs — Documented [streamflags]. Render streams open at the device's own format
  instead, so that nothing resamples after Tapdeck's output limiter
  ([Sample rates and clocks](#sample-rates-and-clocks)).
- **Latency.** Shared mode runs on a period of about 10 ms; `IAudioClient3` offers smaller
  periods but accepts only the event flag — Documented [iaudioclient3]. The ring buffer
  cushion, the user's Buffer setting (2,048 frames by default, about 43 ms at 48 kHz; 1,024 at
  the least, about 21 ms), is larger than either, so the default period is used. The Windows
  app keeps the setting and its four values.
- **Exclusive mode** would lock a device away from every other app. Not used.
- **A device that goes away or changes format** fails the next call with
  `AUDCLNT_E_DEVICE_INVALIDATED`, and the stream is rebuilt automatically — Documented
  [invalid-device]. This goes beyond macOS, which does not notice a device that vanishes
  mid-run: sources that failed to attach are retried when the lists are refreshed, and outputs
  are reopened only when the mix restarts (Verified in the code).
- **Reported latency.** Each output shows the latency its device reports as a hint beside the
  delay control (Verified in the code). The nearest Windows figure is the stream's maximum
  latency from `IAudioClient::GetStreamLatency` — Documented [stream-latency] — to which
  Tapdeck adds the device period (Design); whether it includes the endpoint's own hardware
  latency is Unknown (W11). Bluetooth is expected to under-report as AirPlay does (W11), so
  Line Up keeps using typical values.
- **Listening to a virtual device** creates a running mix from a virtual device's input side
  to the speakers (Verified in the code). Windows users often make a cable their default
  output, so this matters more there: the menu lists the capture side of every cable Tapdeck
  knows ([Feedback detection](#feedback-detection)).
- **Width.** A shared-mode stream follows the format configured for the endpoint, its
  "Default Format" in Sound settings — Documented [device-formats]. Shared mode does not
  support more than eight channels — Documented in one sentence on the USB Audio 2.0 driver
  page [usb-audio-2]; W25 confirms it for a virtual endpoint.

### Device identity, transport and changes

- **One device, two endpoints.** Windows lists render and capture endpoints separately, with
  different IDs, where Core Audio has one device with two scopes. Inputs and outputs are
  matched by ID within their own direction; feedback detection needs the pairing explained in
  [Feedback detection](#feedback-detection).
- **Identity.** An endpoint ID survives restarts and, for USB devices, replugging, but changes
  when the driver is upgraded or reinstalled and can change with a Windows update
  [endpoint-ids]. Build 26100 adds `PKEY_AudioEndpoint_StableId`, which Windows tries to keep
  across driver and system updates but which can be empty [stable-id]. A saved output is found
  by exact ID, then by stable ID, then by a single endpoint with the same name. The last step
  is a deliberate divergence: `AudioDevice.find(uid:name:in:)` on macOS accepts a name only
  together with a matching UID signature (Verified in the code). `devicetest` gets Windows
  cases for it (W19).
- **Names.** `PKEY_Device_FriendlyName`, for example "Speakers (Realtek(R) Audio)" —
  Documented [friendly-name].
- **Transport.** There is no single transport property. The endpoint's form factor
  distinguishes speakers, headphones, headsets, S/PDIF and HDMI-type displays [form-factor];
  Bluetooth and USB come from the device's enumerator. Unknown how reliably (W11).
- **Changes.** `IMMNotificationClient` reports devices added, removed, changing state,
  changing default, and changing properties, the device format among them; its callbacks must
  not block — Documented [notification-client]. Reacting to these events is new behaviour:
  macOS re-reads its device and app lists at launch, when a window or the menu bar popover
  opens, and on Refresh, and listens only to a device's volume and mute and a tap's rate
  (Verified in the code).
- **A device's sample rate.** The macOS harness can set a device's nominal rate (`tapproof
  rate`). No public Windows API sets the shared-mode format; it is the user's choice in Sound
  settings [device-formats]. Not ported.

### Applications as sources

- **Listing.** Windows has no list of "processes doing audio" like the HAL's process objects.
  Each render endpoint lists its audio sessions with their process IDs and states
  (`IAudioSessionManager2`, `IAudioSessionControl2::GetProcessId`, `GetState`) — Documented
  [session-manager2] [session-control2]. New sessions are reported only after the app has
  registered and then called `IAudioSessionEnumerator::GetCount` [register-session-notification];
  notifications need a multithreaded COM thread, and the app keeps its own list, because the
  enumerator can miss new sessions — Documented [session-notification].
- **Apps that have not played yet** have no session. Process loopback can target a process
  that is not playing, which yields silence — Documented [app-loopback-sample] — so the list
  can also offer windowed processes that have not made a sound yet. Whether such a stream
  delivers the app's first sound once it plays is Unknown (W2).
- **Identity across launches.** The bundle identifier's counterpart is the package's
  Application User Model ID for packaged apps and the executable path for desktop apps —
  Documented [get-aumid] [image-name]. Some apps install into versioned folders, so the path
  alone can change with every update; the saved identity is the path, the executable's file
  name and the product name from its version resource, matched in that order (W12).
- **Names.** The version resource's description, then the executable name, then "PID n",
  mirroring `AudioProcess.displayName`.
- **Pinning.** The session PID is kept and checked first, exactly as on macOS, so two
  processes with the same name never swap. Where macOS checks that a pinned PID still has the
  same bundle ID and name, Windows also compares the process creation time recorded when the
  source was pinned [process-times], because PIDs are reused.

### Sample rates and clocks

**Today.** Each source converts to the primary output's rate with AVAudioConverter, rebuilt
when a tap's rate changes; secondary outputs receive the finished mix converted in `fanOut`,
before their own gain and limiter; ring buffers with a cushion absorb the phase difference.
Process taps are drift-compensated only against the default output device, which clocks
their aggregate (`kAudioSubTapDriftCompensationKey`). The mix runs on its primary output's
clock, so whenever that is a different device — a Tapdeck virtual device, for instance — tap
sources drift against the mix just as input devices and secondary outputs do, and drop or
re-prime when their buffers run over or dry (Verified in the code).

**On Windows:**

- **Sources** arrive at the mix's rate, converted by the audio engine (`AUTOCONVERTPCM` with
  `SRC_DEFAULT_QUALITY`) — Documented [streamflags]. Unknown how good that converter is
  compared with AVAudioConverter (W13).
- **Secondary outputs** open at their device's own rate, and Tapdeck resamples the mix before
  `finish()`, exactly where macOS converts, so the −1 dBFS look-ahead limiter stays the last
  stage. Letting the audio engine convert after the limiter could push peaks over the
  ceiling. The resampler is Tapdeck's own, so it can be tested offline. Media Foundation's
  Audio Resampler DSP takes its rates from the media types set on it [audio-resampler];
  nothing documents changing the ratio while it streams, which drift steering would need, so
  it is not used.
- **Drift.** Conversion does not stop clocks from drifting apart, and Windows has no
  aggregate device to reconcile them. At 50 ppm and 48 kHz a buffer gains or loses 2.4 frames
  a second. With the default cushion of 2,048 frames it runs dry after about 14 minutes, and
  the 16,384-frame buffer overflows after about 100; at the smallest Buffer setting, 1,024
  frames, it runs dry after about 7 minutes, and at the largest, 8,192, after about 57 either
  way. macOS ships with the same behaviour for inputs, secondary outputs, and taps whenever
  the primary output is not the default output. Correcting it — steering Tapdeck's resampler
  by each ring buffer's fill level — goes beyond parity, and is built if W5 predicts a re-prime
  within thirty minutes at the default setting, which happens above about 24 ppm.
  `IAudioClockAdjustment` can adjust a render stream's rate [clock-adjustment], but whether it
  combines with the engine's conversion is undocumented, so one mechanism, the resampler, is
  used throughout.

## Mixing and processing

### The mixer and real-time rules

The design carries over: a ring buffer with a cushion per source, the primary output's callback
rendering the mix, each source read into the mix at its own channel pair of the main output (a
channel offset on read, a new source taking the first free pair), secondary outputs fed through
their own ring buffers, fan-out folding a wide mix onto narrower outputs, mix volume and
loudness before fan-out, per-output delay, gain and look-ahead limiter after it, and the file
recorder tapping the mix after its volume. `Mixer.swift` is the specification; it is
re-implemented, not translated call by call, because every device and format call in it is Core
Audio's.

The Windows engine is stricter than the macOS one on its audio threads. On macOS the render
callback takes the mixer's `NSLock`, which the main thread also takes, and each output's meter
lock, which the UI's meter reads take; `EffectChain` takes an `NSLock` and allocates when its
settings change; `AudioRingBuffer` takes an `NSLock` from both sides; `MasterVolume` and
`LoudnessTuning` use `os_unfair_lock`; and the input, tap and conversion paths allocate a
buffer on every callback (Verified in the code). The holds are short and macOS measures clean.
Windows raises the owner of a contended critical section to its waiter's priority
[priority-inversion], but an audio thread that waits at all can still miss its period, so the
port uses:

- single-producer, single-consumer lock-free ring buffers, with overflow handled on the reader
  side;
- settings and the source and output lists published as immutable snapshots swapped in
  atomically, with old snapshots freed later on a thread that is not real-time;
- every per-callback buffer and every delay line allocated in advance, at its maximum size;
- no managed code on an audio thread, ever: events for the UI leave through a dispatcher thread
  inside the engine.

### Effects, loudness, limiter and delay

Shared in substance; see [What can be shared](#what-can-be-shared).

### Device volume

`IAudioEndpointVolume` sets the volume and mute of any endpoint, not only the default one —
Documented [endpoint-volume] — and `IAudioEndpointVolumeCallback` reports changes made through
that interface by any application, Windows' own volume controls included — Documented
[endpoint-volume-callback] [endpoint-volume-controls]. That is the macOS model: an output's
fader is the device's own volume. Whether the keyboard's volume keys reach only the default
device, as on macOS, and whether a headset's own volume buttons are reported, is Unknown
(W29).

One difference: when a device has no volume control in hardware, the audio engine supplies a
software one, which every app playing to the device hears and which the user can change in
Windows' own controls — Documented [endpoint-volume]. On macOS such a device has no volume, and
its fader becomes the mix's level for that output instead (Verified in the code). On Windows:

- **Third-party cables and other endpoints without hardware volume** (`QueryHardwareSupport`
  reports no volume [hardware-support]), such as some HDMI outputs, use the engine's software
  volume as their fader, which every app hears, as with a macOS device volume.
- **Tapdeck's own devices** must not get a second volume. Either the driver exposes a volume
  control it does not apply, so the engine adds none, or Tapdeck holds the endpoint at full
  scale and resets it whenever the callback reports a change. The UI hides it either way, so
  "one volume per place" still holds. Which works better is Unknown (W39).
- **A cable's capture side** has a volume too, and call apps that "automatically adjust
  microphone volume" may move it (Unknown, W35); on macOS a Tapdeck device has no volume to
  move. Tapdeck watches the paired capture endpoint and shows when it is below 100 %.

The master fader carries over unchanged: saved with the settings, only turning down, applied to
every output of every mix after that output's gain (Verified in the code). Tapdeck's own
playback also appears in Windows' volume mixer, where it can be muted [audio-sessions]; Tapdeck
names its sessions, watches their volume, and warns when one is muted or below 100 %.

### AirPlay, Bluetooth and the default device

Windows has no AirPlay, so `MixerModel`'s borrowing of the Mac's output and the 2-second
AirPlay delay are dropped. Bluetooth keeps the 150 ms that macOS uses as its typical delay for
Line Up (a design constant, Verified in the code); how late Bluetooth plays on Windows is
Unknown (W11). No documented API changes the system default endpoint; tools such as
SoundSwitch and AudioDeviceCmdlets use the undocumented `IPolicyConfig` [enumerator]
[soundswitch] [audiodevicecmdlets]. With AirPlay gone Tapdeck has no reason to change it.

It still reads the defaults. "Hear It" adds the system output, or the first real output when
the system output is virtual, and "Mic" adds the built-in microphone, or else the first
non-virtual input (Verified in the code). Windows keeps a default per role — console,
multimedia and communications [device-roles]. Hear It reads the console default, and Mic the
communications default, falling back to the console one; both skip cables.

Bluetooth headsets need the same care as on macOS. On Windows 11 a Bluetooth Classic headset
is one output and one input endpoint; opening its microphone switches it to the hands-free
profile, mono at 8 or 16 kHz — Documented [bluetooth-classic-audio]. LE Audio headsets,
supported since Windows 11 22H2, use other formats, listed per use case by Microsoft
[bluetooth-le-audio]. A headset microphone is never opened as a source unless the user picks
it, and the UI warns when they do.

### Feedback detection

`RoutingGraph`'s algorithm is ported unchanged (M1). What changes is how devices become nodes:
on macOS a device's output and input share one UID — a USB interface's as much as a Tapdeck
device's — so "plays into X" and "captures X" meet at the same node (Verified in the code). On
Windows they are separate endpoints with different IDs, so Tapdeck pairs them:

- physical render and capture endpoints by their container ID, which groups the functions of
  one physical device [container-id] — Documented; Unknown how reliably for every device
  (W11);
- Tapdeck's own devices by the pairs its driver reports in its device list;
- a third-party cable by its names (VB-CABLE's "CABLE Input" plays into "CABLE Output"
  [vbcable]), which the user can correct; whether name-based pairing holds is Unknown (W26).

Excluding Tapdeck from "All system audio" keeps the global source from looping through
Tapdeck itself.

Pairing is one use of a broader question. macOS asks "is this a Tapdeck device?" in many places
— to pick a new mix's default output, to skip virtual devices for Hear It and Mic, to group
the output menu, to word the level fader's help, to keep virtual outputs out of Line Up, to
warn when replacing the original leaves nothing audible, to group the recorder's sources and
to fill the Listen menu (`MixerModel.isVirtual`, Verified in the code). Without Tapdeck's driver
the question becomes "is this a cable?", so the engine keeps one cable table — render
endpoint, paired capture endpoint, product — filled from Tapdeck's driver when it is
installed, from known products (VB-CABLE, Voicemeeter) and from the user, and every one of
those decisions reads it. Hiding the device volume is the exception: only Tapdeck's own
devices hide it ([Device volume](#device-volume)), while a third-party cable shows the
engine's software volume. The start check that refuses a device which is both a source and
an output of one mix compares cable pairs, not IDs.

## Recording

### Recording a mix to a file

`MixRecorder` copies the mix into a ring buffer on the audio thread and writes from a timer
on a background queue; that design ports unchanged. The formats differ:

| Format | macOS today | Windows | Mark |
|---|---|---|---|
| WAV, AIFF | AVAudioFile, 16 or 24 bit (24 by default) | Written directly. `WAVE_FORMAT_EXTENSIBLE` above two channels or above 16 bits [waveformatextensible]. WAV's chunk sizes are unsigned 32-bit and AIFF's signed 32-bit [aiff-spec], so an 8-channel, 24-bit, 48 kHz mix reaches AIFF's 2 GiB after about 31 minutes and WAV's 4 GiB after about 62; a longer WAV continues as RF64, and an AIFF recording stops at its limit with a message | Documented; the size handling Design |
| FLAC | AVAudioFile | Listed by Windows as encodable [supported-codecs]; the encoder classes appear only in the SDK headers [wmcodecdsp] | Unknown (W14) |
| ALAC | AVAudioFile | As FLAC | Unknown (W14) |
| AAC | 128, 192, 256 (default) or 320 kbps, doubled above two channels; the mix's own channel count, untested above two | 44.1 or 48 kHz; 1, 2 or 6 channels; 96, 128, 160 or 192 kbps for mono and stereo, six times those for six channels; 16-bit input [aac-encoder] | Documented |
| MP3 | Not offered: macOS has no encoder | Media Foundation's MP3 encoder, mono or stereo, 32, 44.1 or 48 kHz, up to 320 kbps [mp3-encoder] | Documented |

Consequences:

- The 256 and 320 kbps AAC choices do not carry over, and the AAC default becomes 192 kbps.
- AAC's six-channel layout is 5.1, whose fourth channel is coded as low-frequency only
  [aac-encoder] [waveformatextensible], so it cannot carry three stereo pairs. A mix wider than
  stereo is written as WAV or AIFF, or FLAC if W14 allows; AAC and MP3 stay mono or stereo.
- AAC takes only 44.1 or 48 kHz and MP3 only 32, 44.1 or 48 kHz, so a mix at any other rate —
  88.2 or 96 kHz, or 16 kHz from a headset in hands-free mode — is resampled with Tapdeck's
  resampler before encoding.
- Recordings go to `Videos\Tapdeck` by default, where macOS uses `~/Movies/Tapdeck`, and keep
  the macOS file name patterns. Mix names in file names are cleaned of every character and
  name Windows reserves (`\ / : * ? " < > |`, trailing dots and spaces, `CON`, `NUL` and the
  like) [naming-files]; macOS replaces only `/` and `:`.

### Screen recording

**Today.** ScreenCaptureKit captures a display, a window or one app's windows, leaves
Tapdeck's own windows out unless asked to include them, and delivers BGRA frames at a chosen
15 to 120 fps (60 by default). Audio comes from ScreenCaptureKit — system audio and the
microphone, each written as its own track so they can be edited apart — or from a device
carrying a mix, written as one track per channel pair. AVAssetWriter writes a .mov with H.264
or HEVC and AAC audio (Verified in the code).

| Piece | Windows | Mark |
|---|---|---|
| Capturing a display or a window | Windows.Graphics.Capture, items made from an `HMONITOR` or `HWND` [wgc] [wgc-interop-monitor] [wgc-interop] | Documented |
| Frame rate | `GraphicsCaptureSession.MinUpdateInterval`, from build 26100 [wgc-min-update]; Microsoft's reference describes it only by its signature, and by its name it sets the shortest interval between frames. Tapdeck paces the encoder itself, repeating a frame when none arrives | Documented that it exists; its effect, 120 fps and pacing Unknown (W30) |
| Cursor on or off | `IsCursorCaptureEnabled` [wgc-cursor] | Documented |
| No yellow capture border | `IsBorderRequired` after the user consents through `GraphicsCaptureAccess.RequestAccessAsync` [wgc-border] | Documented; Unknown for an app without package identity (W15) |
| Leaving Tapdeck's windows out | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` [display-affinity], set only while a Tapdeck recording runs with its windows left out and cleared afterwards. Unlike the macOS filter it hides them from every capture meanwhile, other apps' screen sharing included | Documented |
| One app's windows | No single counterpart: a Windows.Graphics.Capture item is one window or one display [wgc-interop] [wgc]; one app's windows would mean one session per window, composited by Tapdeck | Documented; not built (Design) |
| Audio | Windows.Graphics.Capture has none [wgc]. Tapdeck's own capture supplies it: process loopback excluding Tapdeck for system audio, WASAPI for the microphone, or a mix | Documented |
| Size and pixel format | Windows.Graphics.Capture delivers BGRA, and the H.264 encoder takes NV12 and other YUV formats [h264-encoder]; the Video Processor MFT converts and scales on the GPU [video-processor], covering the macOS sizes (native, 2160p down to 480p, and 75, 50 or 25 %) | Documented |
| Audio and video in sync | Each frame carries a system-relative time [wgc-frame-time] and each WASAPI packet a performance-counter position [capture-getbuffer], on the same clock | Documented |
| H.264 | Media Foundation's encoder, hardware when the GPU offers one [h264-encoder] | Documented |
| HEVC | An 8-bit Main profile encoder, available with the HEVC Video Extensions or the GPU [hevc-encoder] [supported-codecs] | Unknown per machine (W16) |
| Container | Media Foundation's MP4 sink takes at most one video and one audio stream, fixed when it is created [mp4-sink-create], and its transcode API takes no more than one audio stream [transcode-api]; Windows lists no QuickTime container among its encoders [supported-codecs]. The WinRT encoding profile can describe several audio tracks [set-audio-tracks], but whether it writes them to MP4 is not stated | Documented; several tracks Unknown (W28) |

Both recording modes carry over: screen and audio, and audio only, which records a mix (and
starts it if it is stopped). Desktop Duplication is not used: it captures whole displays only,
and the app has to draw the pointer itself [desktop-dup].

Several audio tracks are therefore needed even without wide devices: system audio and the
microphone are two tracks on macOS. Unless W28 shows the WinRT pipeline writing them, Tapdeck
writes its own MP4: Media Foundation encodes the samples and Tapdeck writes a fragmented MP4,
which also keeps everything up to the last fragment if the app crashes. Until that writer
exists, system audio and the microphone are mixed into one track. FFmpeg's libavformat would
do the same job under the LGPL 2.1 or later when built without its GPL and non-free parts
[ffmpeg-legal]; it would be Tapdeck's first third-party library beyond Microsoft's own runtime
and samples, recorded in `windows/THIRD_PARTY.md`.

## App shell

### Notification area icon

`NSStatusItem` and its popover become a notification area icon (`Shell_NotifyIcon`) and a
flyout window — Documented [notification-area]. WinUI 3 has no API of its own for it
[winui-tray-issue]; the icon is created with Win32 calls directly.

Windows has its own version of the full menu bar. New icons start in the overflow and
Microsoft reserves promoting them to the user — stated for Windows 7 [notification-area]; on
Windows 11 the user drags them out, or turns them on under Settings › Personalization ›
Taskbar › Other system tray icons [taskbar-support]. Where a new icon starts on Windows 11 is
Unknown (W32). The main window says once where to find the icon.

What else carries over from `MenuBarController` and its panel (Verified in the code):

- the setting that shows or hides the icon;
- the icon filling while any mix runs, in light and dark variants for the taskbar;
- detecting an icon that could not be placed: macOS checks where its window ended up; whether
  `Shell_NotifyIconGetRect` reveals an icon in the overflow is Unknown (W32)
  [notify-icon-rect];
- the flyout's contents: each mix with start and stop, recording and its level, Stop All, the
  master fader, and Open Window, Settings and Quit.

Windows adds three duties. An icon registered by GUID is tied to the executable's path
[notifyicondata], so development and installed builds use separate GUIDs. The icon is added
again when Explorer restarts and broadcasts `TaskbarCreated` [taskbar]. And closing the window
keeps Tapdeck running, so a second launch brings up the running instance's window instead of
starting another.

### Icons

Every glyph in the macOS UI is an SF Symbol, which Apple provides for apps on its own
platforms [sf-symbols], so none ships on Windows. The Windows UI uses Segoe Fluent Icons
[segoe-fluent-icons], with the mapping kept in `windows/PARITY.md`. `tools/make-icon.swift`
draws the app icon with Core Graphics and writes it as PNGs (Verified in the code); run on the
Mac at the Windows sizes, with a small packer, it produces `windows/Resources/Tapdeck.ico`.
The notification area icons are new artwork, filled and outlined in light and dark, because
the macOS ones are SF Symbols. All are committed so that the Windows build needs no Mac. Apps
in the source list show the icon of their executable.

### Diagnostics

Settings › Diagnostics on macOS (`AudioEngineModel`) has three tools: the loopback check (a
440 Hz tone into a virtual device's output, read back from its input, with a verdict and a
`loopback-test.wav`), the input recorder that replaced ffmpeg as a measuring instrument (four
seconds of a device's input to `monitor.wav`, with its peak), and a list of every device with
its channels and rate (Verified in the code). All three carry over and work before Tapdeck has
a driver: they run on a cable pair from the cable table through Tapdeck's own WASAPI path,
write to `%LOCALAPPDATA%\Tapdeck\Diagnostics`, and the device list adds each endpoint's
shared-mode format, state and form factor. `windows/PRIVACY.md` lists these files.

### Settings and saved mixes

`UserDefaults` becomes JSON files under `%APPDATA%\Tapdeck`, written to a temporary file and
moved into place, and the engine owns them, so `tapproof.exe` can test saved libraries too.
The macOS rule carries over: restoring saved state never saves, and nothing is saved before
loading finishes.

The Codable field names and enum values of `SavedMix`, `SavedOutput` (with
`AudioDevice.Transport`), `MixerConfiguration.Source` and `EffectSettings` stay those of macOS.
Windows-only facts — an app's executable path, an endpoint's stable ID, a form factor
`Transport` has no case for — go into new optional keys, never into new enum values. The
Windows reader decodes each mix and each source on its own, so one unreadable entry never
costs the library. That keeps an import between the platforms possible later, but nothing is
promised: macOS has no export, and its `MixLibraryStore.load()` treats a library it cannot
decode as missing and saves a fresh one over it (Verified in the code), so a Windows file must
never be handed to it as it is.

### Translations and the language choice

- `Resources/Localizable.xcstrings` stays the source for every string both apps share.
  `tools/check_localization.py` fails on any catalog entry the Swift code no longer uses
  (Verified in the code), so Windows-only strings go into an overlay catalog,
  `windows/Resources/Windows.xcstrings`. A build step merges both catalogs and runs the
  checker's `check_catalog` on the merged catalog, before placeholders are mapped, so every
  entry has its translations and matching placeholders. A separate check compares the keys the
  Windows code asks for with the merged catalog and fails on any that are missing; it cannot
  use `check_catalog`'s list of used keys, which would also reject every macOS-only string.
  Only then are `%@`-style placeholders mapped to .NET format strings for the app's table.
  The missing-key check also catches a string that a merge from the macOS code removed while
  Windows still uses it; that string moves into the overlay with its translations.
- `Localization.resolve` is plain logic and ports as it is, including the rules for Simplified
  Chinese once `feature/zh-cn` is merged into this branch. Its input changes: macOS passes the
  user's preferred languages, and the Windows counterpart is
  `GlobalizationPreferences.Languages` [globalization-languages];
  `GetUserPreferredUILanguages` lists only display languages installed on the PC
  [ui-languages], so it would miss a language added without its language pack.
- The macOS compiler lists every string the code asks to have translated, and the build fails
  on one without a translation. C# and XAML have no such list, so the Windows UI takes text
  only through one lookup keyed by the English text; a build step extracts those keys from the
  `.cs` and `.xaml` files and from the engine's message table — every user-facing engine
  message declared once, in one header — for the missing-key check. A literal string in XAML,
  or an engine message not declared there, fails the build.
- Japanese and Chinese share code points but not glyph shapes, so the UI sets its language
  on the root element to the chosen language and lets font fallback pick the right forms
  (W38).
- Switching language without a restart works for Tapdeck's own UI as on macOS: the UI looks
  strings up through its own service rather than relying on the process's UI language. Engine
  errors carry the English key and its arguments, and the UI formats them in the chosen
  language. What Windows draws itself, such as the folder picker for recordings, follows the
  Windows display language; on macOS it follows the choice at the next launch. Setting the
  process's preferred UI languages at startup [set-process-languages] may close that gap for
  languages installed on the PC (W38).

### Permissions

| macOS | Windows | Mark |
|---|---|---|
| Audio capture, asked on first use | Nothing documented for loopback | Unknown (W8) |
| Microphone, asked on first use | One switch for all desktop apps, "Let desktop apps access your microphone" [privacy-mic] | Documented |
| Screen recording, asked once, then a relaunch | Windows 11 has a privacy setting for apps taking screenshots of windows or displays [policy-csp-privacy]; whether it stops an unpackaged app capturing by window or display handle is not stated. Removing the border needs the user's consent and a capability declared in a package manifest [wgc-border] | Unknown (W31); removing the border Unknown for an unpackaged app (W15) |

Tapdeck must recognise a refused microphone or screen capture and point to the right page of
Settings › Privacy & security instead of failing silently.

### Signing and installing the app

On macOS, signing decides whether privacy permissions survive a rebuild. On Windows the one
documented permission, the microphone, is a single switch for all desktop apps [privacy-mic],
so a rebuild cannot lose a per-app grant; whether loopback or screen capture keep any per-app
state that a new signature would reset is Unknown (W8, W31), and W8 also checks how Windows
identifies an unsigned or re-signed Tapdeck. Signing decides instead whether the app starts
at all:

- An unsigned or newly signed program meets SmartScreen's "Windows protected your PC" until it
  has a reputation, and EV certificates no longer skip that — Documented [smartscreen].
- On a PC where Smart App Control is on, an app runs only with a good reputation or a signature
  from a certificate authority in Microsoft's Trusted Root Program. A new unsigned build, which
  has no reputation yet, is blocked; there is no per-app exception, and the only way past it is
  to turn Smart App Control off in Windows Security — Documented [smart-app-control]
  [smart-app-control-faq].
- An individual can buy an ordinary (non-EV) code signing certificate, which the CA/Browser
  Forum rules allow for a natural person [csbr], for example SSL.com's individual validation
  certificate at US$129 a year [sslcom-iv], plus key storage, which the rules require on
  hardware [csbr] — a hardware token, a cloud signing subscription, or a cloud key store of
  one's own with a one-time attestation fee [sslcom-iv]. Microsoft's Artifact Signing
  (formerly Trusted Signing, from US$9.99 a month [smartscreen]) accepts individuals only in
  the USA and Canada [artifact-signing-quickstart].

So the app's signing is decided before the first public build; an unsigned preview says that
Smart App Control blocks it. This is a separate, much easier question than signing the driver.

The app installs per user under `%LOCALAPPDATA%\Programs\Tapdeck` without administrator rights.
The Windows App SDK can be deployed self-contained and unpackaged next to the executable
[wasdk-self-contained]. The C# app is also published as self-contained .NET, and the engine,
the app and `tapproof.exe` use the hybrid C runtime, as the same page requires for a fully
self-contained app, so nothing needs a runtime installer or an administrator. MSIX needs a
certificate the PC trusts [msix-signing] and is not used. The driver, if there is one, is a
separate administrator-only step, as `sudo ./install-driver.sh` is today.

- `install.ps1` mirrors `install.sh`: it builds, asks a running Tapdeck to quit (it keeps
  running in the notification area and holds its files), and copies the app into place.
- The installer creates the Start menu shortcut that carries the app's user model ID and
  registers an uninstall entry under the current user's `Uninstall` key, with the value names
  Windows Installer documents for the machine-wide one [uninstall-key] (Design).
- `install-driver.ps1`, run as administrator, replaces `install-driver.sh` and also uninstalls.
- The version resource and the installer carry both copyright lines, as `Info.plist` does, and
  `LICENSE` is installed beside the program, because the MIT licence requires the notice in
  every copy.

### The measurement harness

`tapproof.exe` keeps `tapproof`'s commands wherever Windows has a counterpart — `list`,
`devices`, `rec`, `rec-system`, `mix`, `tone`, `capture`, `loopback`, the offline tests, and
`muxtest` and `muxopts` writing MP4 (both need several-track output: `muxtest` splits a
four-channel signal into two tracks, and `muxopts` writes HEVC with two audio tracks, so it
also needs W16); not `rate`;
`virtual` only once the driver exists — and its rule: audio behaviour is measured through
Tapdeck's own capture path and read sample by sample, never through a third-party recorder.
`Tapproof.app` has no counterpart: it exists so that macOS can ask for permission, and on
Windows a console program falls under the same microphone switch as any desktop app
[privacy-mic].

It adds two commands macOS has not needed. `drift` logs each stream's clock position against
the performance counter. `glitch` plays a continuous tone through a mix, captures the output
back through whole-device loopback, and counts phase jumps. WASAPI reports no render
underrun to the client: the discontinuity flag exists only on the capture side
[capture-getbuffer], and the flags a client sets on a render buffer only mark silence
[render-releasebuffer] — Documented. `glitch` is therefore how "zero discontinuities" is measured on the render side,
and a Windows Performance Recorder trace [wpr] explains any jump it finds.

UI checks capture only Tapdeck's own window, never a screen region, which would pick up other
apps' windows: a small helper captures one window by its handle. The window under test never
sets a display affinity, which would leave it out of every capture [display-affinity]; the
helper restores a minimised window and fails the check on a missing or all-black frame instead
of saving it.

## What can be shared

| File | Lines | Depends on | Carries over |
|---|---|---|---|
| `DelayLine.swift` | 93 | Foundation only | The algorithm, as it is |
| `RoutingGraph.swift` | 33 | Foundation only | The algorithm, as it is |
| `GainStage.swift` | 258 | `os_unfair_lock` in `MasterVolume` | The algorithms; the lock becomes an atomic |
| `Loudness.swift` | 360 | `os_unfair_lock`; `LocalizedStringResource` in one caption | The algorithms; the caption moves to the UI |
| `Effects.swift` | 480 | AVFoundation for one convenience overload; an `NSLock` | The algorithms; settings arrive as snapshots |
| `AudioRingBuffer.swift` | 216 | AVFoundation for one overload; an `NSLock` from both threads | The design, not the code: the Windows buffer is lock-free |
| `Language.swift` | 73 | `CFPreferences`, `LocalizedStringResource` | `resolve` only |
| `Mixer.swift` | 893 | AVAudioFormat, Core Audio IDs, `CATapMuteBehavior` | The design, not the code |
| `MixerConfiguration.swift`, `MixLibrary.swift` | 202 | `UserDefaults`; `Mixer.Source` and `AudioDevice` for conversion and migration | The Codable schema, not the storage |

About 1,440 lines of signal processing with almost nothing platform-specific; about 1,190 of
them (effects, loudness, gain stage, delay) are ported and checked against reference vectors,
the routing graph by `graphtest`, and the ring buffer keeps only its design. The repository's
history begins on 2026-09-06; the ring buffer arrived on 2026-09-10 and the other five files
on 2026-09-13. Counting the commit that added each, they have been touched by one to five
commits, against twenty for `Mixer.swift` (Verified in the git history). That is five weeks of
history, not proof of stability, which is why the parity checks below run in CI rather than
once.

Two ways to carry it over:

1. **Compile the Swift files on Windows.** Swift supports Windows (6.4.1 as of October 2026)
   [swift-windows] [swift-platforms], but these files cannot be compiled there unchanged.
   `Effects.swift` and `AudioRingBuffer.swift` import AVFoundation, an Apple framework.
   `GainStage.swift` and `Loudness.swift` use `os_unfair_lock`, which belongs to Apple's `os`
   library [apple-os-unfair-lock], and `Loudness.swift` uses `LocalizedStringResource`, which
   neither open-source Foundation defines [swift-foundation] [corelibs-foundation] (both
   searched in October 2026). This fork leaves these DSP files as the original project has them
   and changes other macOS files only where it must (build scripts, the copyright and fork
   notices in `LICENSE`, `README.md` and `Info.plist`, and, on `feature/zh-cn`, the Simplified
   Chinese language choice), so that merges stay clean. The Swift route would therefore need
   shims around every Apple-only use, and any future one would break the Windows build at merge
   time.
2. **Port them and prove the port.** Recommended. The parity machinery:
   - **Reference vectors.** A generator under `windows/tools` compiles the unchanged
     `Sources/Engine` files on the Mac (and, for the schema fixtures,
     `MixerConfiguration.swift` and `MixLibrary.swift` from `Sources/App`) and writes input and
     output for every effect at several settings and sample rates, the loudness meter's
     calibration tone, the normaliser through a level jump and a pause, both limiters, the
     delay line's crossfade and the gain ramp. They are committed as raw float files (the
     repository ignores `*.wav`), and a macOS CI job regenerates them and fails when the
     committed ones are stale.
   - **Tolerances that can hold.** Neither Apple's nor Microsoft's math library rounds `exp`,
     `pow`, `log10` and the trigonometric functions correctly, and their errors differ —
     Documented [libm-accuracy] — while the gate, compressor and limiters make threshold
     decisions on those values. Each test therefore has a residual limit and allows a
     one-sample shift at a threshold; only a source with every effect off must match bit for
     bit, as macOS promises. The limits start around −120 to −100 dBFS and are set per effect
     by the first Windows run (Design). Floating-point contraction is off on both compilers.
   - **A schema contract.** The same generator writes the default `EffectSettings` as JSON, its
     keys, the equaliser presets, the `LoudnessTuning` defaults, and `SavedMix` fixtures
     including older formats. The Windows tests read them.
   - **A golden mix.** The Swift components composed in `Mixer.render`'s order, offline,
     against the C++ mixer with fake devices.
   - **`windows/PARITY.md`.** Each Swift file, its Windows counterpart, the last macOS commit
     followed, and the deliberate divergences (such as device matching by name).

When this branch merges a DSP change from the macOS code, the stale vectors show exactly which
Windows code has to follow.

## Language and UI stack

What the choice has to satisfy:

1. Real-time audio threads that never pause for a garbage collector or an allocation.
2. Direct use of COM, WASAPI, Media Foundation, Windows.Graphics.Capture and kernel
   streaming.
3. A UI that looks at home on Windows 11, with a notification area icon.
4. One developer, working partly from a Mac.
5. DSP that behaves like the macOS engine, and saved mixes in the same schema.
6. Little or no third-party code, as [`THIRD_PARTY.md`](../THIRD_PARTY.md) states today.

A kernel driver, if there is one, is C or C++ under every option, built with MSVC and the WDK,
and shares only a header with the engine; the table leaves that common toolchain out.

| Option | Real-time | Windows APIs | UI | Copies of the mix schema | Toolchains and interop | Main risk |
|---|---|---|---|---|---|---|
| **A. Swift for everything** | No collector; reference counting must stay off the audio thread | COM by hand through C headers; WinRT through swift-winrt [swift-winrt] | WinUI 3 through projections generated with swift-winrt; the ready-made WinUI and Windows App SDK packages were archived in October 2025 [swift-winui] [swift-windowsappsdk] | 0 | Swift | The macOS files do not compile on Windows unchanged (see above); the thinnest UI path. Arc for Windows was built this way [arc-windows] and released in April 2024 [arc-windows-release] |
| **B. Swift engine, C# UI** | As A | As A | WinUI 3 or WPF in C# | 0 in Swift, 1 in C# | Swift, .NET, a C interface | As A, plus a second language for the UI |
| **C. C++ engine, C# UI** | No collector in the engine | First-class: Microsoft's process loopback sample is C++ only [app-loopback-source] | WinUI 3 or WPF in C# | 2 | CMake/MSVC, .NET, a C interface | A hand-written interface and a hand-ported engine |
| **D. C# for everything** | A collector in the audio path; low-latency modes give no guarantee [gc-latency] | CsWin32 [cswin32] or .NET's own COM generator [dotnet-com-generator]; NAudio 3 (released August 2026 [naudio-release]) includes process loopback [naudio-builder]; Microsoft has a C# Windows.Graphics.Capture sample [wgc-csharp-sample] | WinUI 3 or WPF | 1 | .NET only | Collector pauses heard as gaps under load |
| **E. Rust engine** | No collector | `windows-rs` covers Win32, COM and WinRT [windows-rs] | Third-party toolkits, or a C# UI | 2 | Cargo, .NET, a C interface | Smaller pool of examples; samples need translating |
| **F. C++ with Qt or JUCE** | No collector | First-class | Qt (LGPL), JUCE (AGPL or commercial) [qt-licensing] [juce-licence] | 1 | CMake/MSVC | Licences and size; neither looks like Windows 11 |

**Recommendation: C.** It makes real-time safety structural: no collector can stop an audio
thread, whatever the UI process allocates. The sample the engine depends on most, process
loopback, exists only in C++ [app-loopback-source], and WASAPI and Media Foundation are native
COM interfaces that C++ calls directly, with no projection or interop layer between. And the
engine's DSP library and its tests also compile with Apple's clang, so the DSP milestone is
developed on the Mac, with Windows CI confirming the same results. The costs are designed down:
the C interface is coarse (mix state and commands as JSON in the macOS Codable schema, meters
as fixed arrays), its C# side is generated from the header with ClangSharp [clangsharp], and
parity is checked in CI.

**UI framework**: WinUI 3 provisionally; the Windows App SDK's current line is 2.x and can be
deployed self-contained and unpackaged [wasdk-release-channels] [wasdk-self-contained]. Its
risks — no tray API, unpackaged deployment, a XAML compiler that does not run on the Mac —
are settled in a two-to-three-day spike at the start of the app milestone, with WPF as the
fallback. The C# view models stay free of either framework, so switching is cheap.

**Runner-up: D**, if one toolchain matters more than the structural guarantee, and only if a
collector soak in the first week (W27, scheduled in M0 while D is considered) shows no
glitches. B is not the runner-up: its one
advantage, a single DSP source, is lost to the shims described above.

**Between engine and UI**: `tapdeck_engine.dll` with opaque handles; commands and state as
JSON; meters polled at 20 Hz, as `MixerModel`'s meter timer does today; device and session
events delivered on the engine's dispatcher thread, never from an audio thread; errors as
English keys with arguments. `tapproof.exe` uses the same interface, so the harness tests what
the app runs.

## The virtual device driver

### What the macOS driver does

`Driver/TapdeckDriver.c` is a user-space `AudioServerPlugIn`: up to 8 loopback devices of up
to 16 channels each, at 44.1, 48, 88.2 or 96 kHz, created, renamed and removed while Core
Audio runs, through the custom property `'tpdv'`. Each device keeps the UID the app chose for
it, also across a rename; object IDs come from a counter and are never reused while Core Audio
runs. The device list is pushed again at every launch because the driver forgets it when Core
Audio restarts, and the real-time path takes no locks. Signed with the shared self-signed
certificate, it loads, because Core Audio's plug-in host does not validate libraries (all
Verified on macOS).

### What a Windows driver involves

No documented user-mode way to add an audio endpoint was found. Windows audio drivers are
PortCls (WDM) or ACX (KMDF), both kernel-mode — Documented [acx-overview] — and a Microsoft
support engineer on Microsoft Q&A says a virtual endpoint needs a WDK driver
[ms-qa-endpoint].

| macOS driver | Windows driver | Mark |
|---|---|---|
| A user-space plug-in | A kernel-mode PortCls WaveRT or ACX driver. Microsoft's samples — SysVAD, SimpleAudioSample, ACX AudioCodec — have no real loopback; they generate tones on the capture side [sysvad-readme] [simpleaudio-tone] [acx-tone]. Tapdeck writes the ring buffer between the render and capture sides itself, as it does on macOS. | Documented |
| Devices created and removed live | A PortCls driver can register and unregister endpoint filters at runtime, as SysVAD does for Bluetooth hands-free endpoints [dynamic-subdevices] [sysvad-bthhfp]; ACX can add and remove circuits at any time [acx-circuits]. No sample triggers this from an app. | Documented; Unknown when driven by the app (W20) |
| A name per device | The endpoint's name can be set when it is created, as SysVAD sets the interface friendly name of the endpoints it adds [sysvad-bthhfp], and users can rename endpoints in Sound settings; no documented way renames one in place [friendly-names]. | Documented; renaming Unknown (W21) |
| 2 to 16 channels | Shared mode does not support more than eight channels [usb-audio-2]. Windows devices offer 2 to 8 channels, so four stereo pairs at most. | Documented; W25 |
| 44.1 to 96 kHz, one rate per device | Data ranges per pin; the shared-mode format is the endpoint's default, set by the INF and changeable by the user [oem-format] [device-formats]. Render and capture sides each have their own default, so the driver offers each side only the device's current rate, changed through the private property set. | Documented; keeping both sides at one rate Unknown (W33) |
| Custom property `'tpdv'` | A private KS property set, sent with `IOCTL_KS_PROPERTY` or through `IKsControl` [audio-property-requests] [ikscontrol]. Whether a standard user may send it is not documented for audio filters. | Documented; Unknown (W22) |
| Forgets its devices when Core Audio restarts | A driver can keep its list in its device's registry key [ioopendeviceregistrykey], so devices survive a restart without the app. | Documented |
| The app-chosen UID kept for good; object IDs never reused while Core Audio runs | Each endpoint's reference string is derived from the device's UID and kept with the list, so restarts and re-creation keep its endpoint ID. Whether reusing it after a width change brings back a stale cached format is the Windows form of the macOS object ID bug; if it does, only a width change gets a fresh string, which, unlike macOS, costs the endpoint ID. | Unknown (W20) |
| Timestamps from the host clock, a 16,384-frame period | A WaveRT driver with no hardware advances its positions from a high-resolution kernel timer; how evenly that runs under load is part of W20. | Unknown (W20) |
| Logs to the system log | Event Tracing for Windows, through TraceLogging or WPP [tracelogging]; `windows/PRIVACY.md` says where the logs go. | Documented |
| A lock-free real-time path | The same rule, plus memory integrity (HVCI) compatibility: no-execute pool, no writable and executable sections [hvci]. | Documented |

The driver is written against the documented interfaces, as `TapdeckDriver.c` was, using the
samples as reference. Code taken from them stays under their licence, the Microsoft Public
License, and is recorded in `windows/THIRD_PARTY.md`.

**Installing** needs administrator rights on every route. A root-enumerated device is created
with `SetupDiCreateDeviceInfo` and the class installer, as Microsoft's DevCon sample does
[setupdi-createdeviceinfo]; alternatively a software device is created with `SwDeviceCreate`,
which Windows removes when its handle closes unless its lifetime is extended with
`SwDeviceSetLifetime` [swdevicecreate] [swdevice-lifetime]. The package is staged and removed
with PnPUtil [pnputil]. The INF keeps to the driver isolation rules Microsoft enforces on
signing submissions since November 2025 (registry writes under HKR, files in the driver store)
[driver-isolation-blog] [infverif-h].

### Signing a kernel driver

Since Windows 10 version 1607, a new kernel driver loads with Secure Boot on only when
Microsoft signed it through the hardware program; cross-signing has ended — Documented
[driver-signing-policy] [cert-deprecation]. In April 2026 Microsoft added the **Windows Driver
Policy** to Windows 11 24H2, 25H2 and 26H1: after an evaluation period (250 hours of uptime and
three restarts without a violation, and a driver that would be blocked counts as one and
resets the count) it enforces, and then only drivers signed through full certification (WHCP)
and an allow list of older cross-signed drivers load — Documented [driver-policy-blog]
[driver-policy-support]. Neither page mentions attestation-signed or
test-signed drivers.

| Route | What it takes | Where the driver loads | Mark |
|---|---|---|---|
| **Test signing** | A self-made certificate, `bcdedit /set testsigning on` with Secure Boot off; a "Test Mode" watermark; with memory integrity on, the driver must still be test-signed [testsigning] | Only on PCs set up that way | Documented; under the Windows Driver Policy Unknown (W24) |
| **Preproduction signing** | A hardware program account and an EV certificate; the package submitted through the Hardware Dev Center API; the test PC provisioned to trust Microsoft's test root [driver-signing-offerings] [preprod-install] | Only on PCs provisioned that way, with Secure Boot and memory integrity on | Documented; under the Windows Driver Policy Unknown (W23, repeated once a preproduction-signed build exists) |
| **Attestation signing** | A hardware program account and an EV certificate; a CAB uploaded to Partner Center; no HLK tests [code-signing-attestation] [code-signing-reqs] | Windows 10 and 11 client, not Server; Microsoft now describes it as for testing [driver-signing-offerings] | Documented; on a PC enforcing the Windows Driver Policy Unknown (W23) |
| **WHCP (full certification)** | The same account and certificate, plus HLK testing: a Windows Server controller and physical test PCs, run for each Windows version [hlk-prereqs] [driver-signing-offerings] | Everywhere, including Windows Update and Server; trusted by the Windows Driver Policy [driver-policy-support] | Documented |
| **Custom kernel signers** | A code integrity policy signed with the PC's own Secure Boot keys, a clean install, any edition but Home [custom-kernel-signers] | The developer's own machines | Documented; not for distribution |
| **Artifact Signing** | — | User-mode code only; it issues no EV certificates and does not sign kernel drivers [artifact-signing-faq] | Not possible |
| **A non-Microsoft signature** (SignPath, any CA, new cross-signing) | — | Not for a new driver with Secure Boot on [driver-signing-policy]; only older cross-signed drivers on Microsoft's allow list still load. The open-source Virtual-Audio-Driver, whose builds are signed through SignPath [vad-repo], is reported failing with Code 52 [vad-issue15] | Not possible |

**The account and the certificate.** Registering for the hardware program needs an EV code
signing certificate, a Microsoft Entra global administrator, company details or a D-U-N-S
number, a legal contact, and since October 2025 an identity check of the primary contact —
Documented [hardware-program-register] [hw-verification-blog]. No Microsoft page describes a
route for individuals. Under the CA/Browser Forum's rules, EV certificates go only to private
organisations, government entities, business entities and international organisations; a
sole proprietorship counts as a business entity if it has filed with a registration agency,
has a verifiable address and its owner is verified face to face, and a natural person cannot
get one — Documented [csbr]. The keys must sit on hardware, and certificates last at most 460
days [csbr].

What that means in practice, as of October 2026:

- SSL.com sells EV code signing at US$349 for one year (less per year on longer terms) and a
  "sole proprietor" EV at US$359, which its product page markets to individual hardware
  partners who need Partner Center and says needs no business entity [sslcom-ev]
  [sslcom-sole-prop]. Its application guide offers a notarised identity form for a sole
  proprietor with no government registration, yet still asks for a listing in business
  directories such as Dun & Bradstreet [sslcom-sole-guide], which sits uneasily with the rules
  above. Key storage costs extra: a hardware token, which SSL.com warns may not suit kernel
  driver signing, or a cloud signing subscription [sslcom-ev].
- In mainland China, WoTrus resells a GlobalSign EV certificate at ¥4,288 a year and a DigiCert
  one at ¥6,888, to organisations only, and writes that an individual business (个体工商户)
  usually does not qualify [wotrus-ev] [wotrus-digicert-ev] [wotrus-article]. Sectigo accepts
  sole proprietorships with a notarised face-to-face form [sectigo-f2f].
- Whether the user can get an EV certificate at all — as a 个体工商户, or as an individual from
  SSL.com — is Unknown: no CA states it for this case, so M0's paper check asks them.

### Realistic options for this fork

1. **No driver of Tapdeck's own.** Tapdeck plays into speakers, headphones and any virtual
   cable the user has installed. VB-CABLE is donationware with one free cable, may be bundled
   with another app's installer if VB-Audio is credited and the donation option stays
   visible, and its paid A+B and C+D cables may not be bundled [vbcable] [vb-licensing];
   Voicemeeter's virtual inputs are another source of cables [voicemeeter]. Costs nothing, but
   Tapdeck cannot create, name or widen devices. How VB-CABLE is signed, and so whether it keeps
   loading once the Windows Driver Policy enforces, is not published (W26).
2. **Tapdeck's driver, test-signed**, on the developer's own machines: free, offline, with
   Secure Boot off and the Test Mode watermark, and possibly with the Windows Driver Policy
   removed (W24). Right for building and testing the driver; not something to give to other
   people.
3. **Tapdeck's driver, attestation-signed**: a registered business, an EV certificate
   (US$349–359 a year at SSL.com, ¥4,288–6,888 a year through WoTrus, plus key storage), and
   the hardware program. Preproduction signing then also allows testing with Secure Boot on, for as
   long as the Windows Driver Policy allows it. The driver may still stop loading on a PC
   enforcing that policy (W23).
4. **Tapdeck's driver, WHCP-signed**: option 3 plus an HLK lab for every Windows version. The
   only route Microsoft names as trusted going forward, and heavy for one person.
5. **An existing open-source driver**: none was found that is Microsoft-signed and
   permissively licensed. Virtual-Audio-Driver (MIT with MS-PL parts) is not Microsoft-signed
   and has no loopback [vad-repo]; Synchronous Audio Router is GPL-3.0, does not load with
   Secure Boot on, and ships unsigned prereleases [sar]; Scream is cross-signed and, on Windows
   11, installs only with Secure Boot off and test mode on [scream].

**Recommendation**: option 1 for everything up to and including the app and recording; option
2 when the driver milestone starts; options 3 or 4 only after M0's paper check answers the
business, certificate and cost questions, and W23 has been run — before any money is spent.
Tapdeck for Windows is designed to be worth having without its own driver.

## Development setup

- **A Windows machine is needed from the first milestone** (see
  [Decisions](#decisions-for-the-user)):
  - a real x64 PC for every timing measurement, because virtual machines emulate their sound
    devices;
  - optionally, in addition, Parallels Desktop on the Mac, which Microsoft lists as an
    authorised way to run Windows 11 on Arm on M1 to M3 Macs (Parallels Desktop 18 to 20; later
    versions are not listed), each virtual machine needing its own Windows 11 Pro licence
    [win11-arm-mac]. It suits functional checks and UI work. Parallels offers no
    virtualisation-based security [parallels-vbs], so memory integrity cannot be tested there,
    and loading a test-signed ARM64 driver in it is Unknown (W18).
- **On the PC**, the repository is cloned from GitHub into a short ASCII path outside OneDrive,
  work is exchanged only through git, and the development tools run natively there.
- **On the Mac**: the DSP port and its tests (Apple clang), the reference vector generator, the
  icon generator, reviews.
- **Architectures**: the engine and app are built for x64 first; Windows 11 on Arm runs x64
  programs through its Prism emulator [prism], so one build serves both while the app matures.
  The driver, being kernel code, is built for the test machine's own architecture.
- **CI**: GitHub Actions. Since June 2026 `windows-latest` and `windows-2025` carry Visual
  Studio 2026 with the WDK extension; among the x64 labels only `windows-2022` keeps Visual
  Studio 2022, while `windows-11-arm` still has it and `windows-11-vs2026-arm` has Visual
  Studio 2026 [runner-images] [runner-images-vs2026]. A label does not pin a toolchain, so the
  build pins the WDK through its NuGet packages or the EWDK [wdk-nuget] and prints the Visual
  Studio, SDK and WDK versions in its log. A macOS job regenerates the reference vectors.
- **Toolchain**: MSVC (C++20), the Windows SDK, the WDK for the driver, the .NET SDK for the
  app. CMake builds the engine and harness, MSBuild the driver, `dotnet` the app; a `build.ps1`
  runs them in order, as `build.sh` does.
- **Layout**: everything Windows-specific lives under `windows/` (`engine`, `cli`, `app`,
  `driver`, `tests`, `tools`, `Resources`, `PARITY.md`, and a `README.md`, `PRIVACY.md` and
  `THIRD_PARTY.md` of its own), except its documents under `docs/` (this plan and
  `windows-platform-limits.md`) and the CI workflows under `.github/workflows/`. All of these
  are new files; the Windows work leaves the macOS sources and root documents as they are (the
  fork changes them only for its build scripts, its copyright and fork notices, and, on
  `feature/zh-cn`, the Simplified Chinese strings and language choice, whose conflicts are
  resolved there), so merges from the macOS code stay free of conflicts. The root
  `.gitattributes` makes every text file LF; a `windows/.gitattributes` gives CRLF to any file
  type a Windows tool insists on.
- **Merging**: macOS changes reach this branch through `main`, and `feature/zh-cn` is merged in
  as well, so translation conflicts are resolved once, on `feature/zh-cn`. Every milestone ends
  with a merge and the parity backlog cleared.
- **Identifiers**: the Windows build uses this fork's own identifiers for the app's user model
  ID, the notification icon's GUID, the driver's hardware ID, the KS property set GUID and the
  virtual device ID prefix, not the macOS bundle identifiers.
- **A Windows map**: test results go into `docs/windows-platform-limits.md`, the counterpart of
  `platform-limits.md`, from the first week on.

## Milestones

Each milestone ends in a result that can be checked. Sizes are relative: S is days, M a week or
two, L several weeks. M0 and M1 run at the same time; the first build for daily use is M3.

### M0 — Platform spike and the signing check (S)

- **On the Windows PC**: a throwaway `tapproof.exe` built from Microsoft's ApplicationLoopback
  sample, with `list`, `rec <app> <seconds> out.wav`, a tone played to an output, `glitch`, and
  `drift`, which logs each stream's clock position against the performance counter for a
  process loopback capture, a USB microphone and a second output.
- Functional tests, possible in a virtual machine: W1, W2, W4, W6, W8, W10, W12, W34, W36, W37.
  Timing tests, on the real PC: W3, W5, W7, W11, W13 (the engine's converter; compared with
  Tapdeck's resampler once M4 has it), W26 with Secure Boot on, and a first W17 with a stand-in
  load; W27 too while option D is still considered.
- **W23**: a third-party driver confirmed to be attestation-signed (not WHCP) is installed on a
  PC with Secure Boot on and test signing off. While the Windows Driver Policy is in
  evaluation, the code integrity log shows whether that driver is audited as one that would be
  blocked (event 3076), and such a driver resets the evaluation counters, so the PC may never
  reach enforcement while it is installed [driver-policy-support]. W23 is recorded from those
  events, confirmed under enforcement only on a PC that got there before the driver was
  installed, and before any money is spent on option 3. W26's policy question is answered from
  the same events.
- **On paper, the same week**: ask Sectigo and SSL.com (and a Chinese reseller, if the user
  registers there) whether the business form the user can register, or an individual, qualifies
  for EV; the cost and lead time of the certificate and of the hardware program.
- **Done when** process loopback has a go or no-go as the source mechanism,
  `docs/windows-platform-limits.md` holds the results, and it is known whether the user can get
  the account and the certificate that options 3 and 4 need.

### M1 — Core DSP on the Mac (S)

- In C++: the lock-free ring buffer, `GainRamp`, `MasterVolume`, `LookaheadLimiter` and
  `RoutingGraph`, about 500 of the 1,440 lines, enough for a first mix.
- The reference vector generator for these, its macOS CI job, and a Windows CI build.
- A new `ringtest` for the ring buffer, which has no macOS test: priming, silence and re-priming
  on underflow, overflow handled at the reader, channel offsets on read, and a two-thread stress
  run under ThreadSanitizer on the Mac.
- **Done when** `graphtest`, `gaintest`, `limittest` and `ringtest` pass on the Mac and in
  Windows CI with the same results, the C++ `GainRamp`, `MasterVolume` and `LookaheadLimiter`
  match the committed reference vectors within their limits on both, and the macOS CI job fails
  on a deliberately stale vector.

### M2 — A first mix in `tapproof.exe` (S–M)

- Sources (apps, all system audio excluding Tapdeck, inputs) into one output, typically a cable,
  plus Hear It on an output at the same rate, with a WAV recording. Each source is read into
  the mix at its own channel pair of the main output, keeping `mix`'s `<app>@<first channel>`
  placement.
- Driven by `TAPDECK_MASTER`, `TAPDECK_MIX_VOLUME` and `TAPDECK_RECORD_FILE` (WAV only), plus new
  variables for input devices; `TAPDECK_OUTPUT_DELAYS` and `TAPDECK_LOUDNESS` follow in M4 with
  the delay line and the normaliser, `TAPDECK_RECORD_FORMAT` in M6, and `TAPDECK_REPLACE` in M9.
- Streams rebuilt after `AUDCLNT_E_DEVICE_INVALIDATED`, and device changes followed through
  `IMMNotificationClient`.
- W19 run on the real PC.
- **Done when** two apps measure at least 100 dB apart (113 dB on macOS), a 997 Hz tone comes
  out at 997 Hz at every mix rate, ten minutes show zero glitches, a USB output unplugged and
  replugged mid-mix comes back without stopping the mix, and the mix has carried a real call
  through a cable.

### M3 — The app, first slice (M)

- **First, a two-to-three-day UI spike**: WinUI 3 unpackaged and self-contained, the
  notification area flyout, engine events arriving from the dispatcher thread, and W38; WPF if
  it stalls.
- **The string pipeline** (overlay catalog, key extraction from the UI and the engine's message
  table, checks) before the first UI string.
- Mixes, sources, outputs, source, mix, master and device faders, mute, each source's channel
  pair on the main output and Separate, start and stop, the saved library, Hear It, Mic,
  Listen, the cable table with cable pairing for feedback checks, and the notification area
  icon, in English; Ctrl+R for the mix's ⌘R, which starts and stops it (Verified in the code).
  A secondary output at another rate is refused with a message until M4.
- The Windows-only duties of the first slice: re-attaching an app when its session reappears,
  the silent-source flag, the ducking opt-out and the call warning, naming Tapdeck's sessions
  and warning when one is muted, watching a cable's capture volume, the headset microphone
  warning, and pointing to the right privacy page when access is refused.
- W29, W32 and W35 on the way.
- **Done when** it has been used for a week to send mixes into Zoom or OBS through a cable, and
  a mix that captures a cable's capture side while playing into its render side is refused
  before it starts.

### M4 — The full engine (M)

- The rest of the DSP: `EffectChain` and `Biquad`, `LoudnessMeter` and `LoudnessNormalizer`,
  `PeakLimiter`, `DelayLine`, and Tapdeck's resampler with tests of its own (frequency
  response, aliasing, ratio tracking under a simulated ±300 ppm skew).
- The rest of the parity machinery: schema contract, golden mix, `windows/PARITY.md`; the tests
  `fxtest`, `loudtest`, `delaytest`, `devicetest` (with Windows device matching) and `l10ntest`
  (with the Simplified Chinese cases).
- Secondary outputs at other rates through the resampler; W5 repeated through the fan-out;
  drift correction if W5 predicts a re-prime within thirty minutes at the default Buffer
  setting.
- **Done when** every offline test matches on the Mac and in Windows CI; a thirty-minute soak
  with the real UI under CPU load and a GPU H.264 encode shows zero glitches on a path that
  crosses no clock boundary (a tone generated in the engine, played to the primary output and
  read back through loopback), with drift re-primes on the other streams reported separately
  (W17); and a 997 Hz tone reaches a 44.1 kHz secondary output of a 48 kHz mix at 997 Hz with
  zero glitches for thirty minutes.

### M5 — The app, complete (M)

- The effects popover, Even Out, delay and Line Up, LIMIT, Settings (Buffer among them),
  Diagnostics, and switching between English, Japanese and Simplified Chinese without a
  restart.
- **Done when** every control of the macOS app outside recording (M6), virtual devices (M7) and
  replacing the original sound (M9) has its Windows counterpart or a recorded reason why not;
  every Windows-only duty this plan names has a row in `windows/PARITY.md`, done or deferred
  with a reason; and the diagnostics loopback check passes on a cable.

### M6 — Recording (M)

- A mix to WAV, AIFF, AAC and MP3, and to FLAC and ALAC if W14 allows; each mix's Record
  button, the flyout's recording row, and the Recording tab with Ctrl+R and Ctrl+. for its ⌘R
  and ⌘. (Verified in the code).
- Screen recording through Windows.Graphics.Capture and Media Foundation's encoders, with
  Tapdeck's fragmented MP4 writer — one track per source (system audio, microphone) or per
  channel pair — unless W28 shows the WinRT pipeline writing several tracks; W15, W16, W30 and
  W31 on the way.
- **Done when** `muxtest` passes offline, a recording of system audio and the microphone opens
  with two tracks in an editor, a 997 Hz tone recorded in each format comes back at the
  expected level, and the macOS recording controls have their counterparts.

### M7 — The driver, for development (L)

Test-signed, for the developer's own machines; whether it is ever distributed is decided in M8
from M0's answers and W23.

- A loopback driver from the PortCls WaveRT patterns SysVAD demonstrates (runtime endpoints and
  names are shown there; ACX is the alternative), up to 8 devices of up to 8 channels, the
  private property set, the list kept in the registry, reference strings derived from the
  devices' UIDs; and a test build offering 16 channels, for W25's first question.
- HVCI-compatible; Driver Verifier on real hardware.
- The app's virtual device settings, as on macOS.
- **Done when** a tone sent into a device comes back at the expected level; four pairs on an
  8-channel device measure at least 100 dB apart, and Zoom and OBS read it; devices are created
  and removed from Settings while another device keeps playing, and renamed as W21 decides; the
  list survives a reboot with the app not running; the driver loads with memory integrity on
  and runs a thirty-minute soak clean under Driver Verifier's standard settings; and W18, W20,
  W21, W22, W24, W25, W33 and W39 are recorded.

### M8 — Distribution (M)

- The app's signing (decided before the first public build), a per-user installer and
  uninstaller, and SHA-256 files for downloads as for the dmg.
- The driver route chosen from M0's answers and W23, or none.
- `windows/README.md`, `PRIVACY.md` and `THIRD_PARTY.md` completed.
- **Done when** a fresh Windows 11 PC with no .NET or Visual C++ runtime installed installs,
  runs and uninstalls the release; on a PC with Smart App Control on, a signed release runs, or
  an unsigned preview's download page says that it is blocked; and the download passes its
  SHA-256 check.

### M9 — Parity and Windows extras (M)

- Replacing the original sound, if W6 and W10 allow, and `TAPDECK_REPLACE` in the harness. Each
  mute or route is recorded with its previous value before it is changed, and the uninstaller
  and `install.ps1` replay that record after asking Tapdeck to quit.
- All system audio minus the apps listed separately (W9).
- Other apps' own volume, which Windows allows and macOS does not.
- **Done when** each item either passes its check — a replaced app is silent on the speakers,
  comes back after Tapdeck is killed and relaunched, and is audible on its own device after
  Tapdeck is killed and uninstalled; an app listed on its own is never heard twice in "All
  system audio"; another app's volume set in Tapdeck shows in Windows' volume mixer — or
  `windows/PARITY.md` and the UI record why it is not offered (W6, W9, W10).

## Tests to run

| Test | Question |
|---|---|
| **W1** | Does process loopback activate and deliver audio on the newest builds of 24H2, 25H2 and 26H2 on x64, and on Arm (26H2, or 26H1 on a new Arm PC) if a device is at hand? |
| **W2** | For Chrome, Edge, Firefox, Discord, Spotify, the new Teams and WebView2-based apps: which process owns the audio session, does including the tree's root capture it, is each app heard in an exclude-Tapdeck stream too, does any stay silent, and does a stream opened before an app's first sound deliver it? |
| **W3** | Played as a 997 Hz tone, does an app arrive at 997 Hz at mix rates of 44.1 and 48 kHz while the playing device runs at another rate? |
| **W4** | Does process loopback deliver packets during silence — with the target's stream open but silent, and after it has closed — and does whole-device loopback stop during silence as reported? |
| **W5** | How far do a process loopback stream, a USB microphone and a second output drift against the primary output over thirty minutes, without correction? |
| **W6** | Is process loopback taken before or after the app's session volume and mute, the device volume, and the device's effects? Can another app's session volume be set from Tapdeck? |
| **W7** | Separation between two apps playing at once (113 dB on macOS), including the apps from W2. |
| **W8** | With "Let desktop apps access your microphone" off: does loopback still work, and what does opening a microphone return? How does Windows identify an unsigned or re-signed Tapdeck in its privacy settings? |
| **W9** | "All system audio" as a sum of include streams: CPU use with twenty streams, and the sound lost before a new stream starts. |
| **W10** | Per-app routing through `IAudioPolicyConfigFactory` to a third-party cable or an output nobody listens to: does process loopback keep capturing the app, does the route outlive Tapdeck, and is it restored after a crash? |
| **W11** | Telling Bluetooth, USB, HDMI and built-in endpoints apart, pairing a physical device's render and capture endpoints by container ID, and how late Bluetooth plays against what it reports. |
| **W12** | Which saved identity finds Chrome, Edge, Discord, Spotify, Zoom, Teams and a game again after an update? |
| **W13** | Quality of the audio engine's conversion (`SRC_DEFAULT_QUALITY`) against the same measurements as AVAudioConverter and Tapdeck's resampler. |
| **W14** | Are the FLAC and ALAC encoders present and usable from a desktop app, and for which channel counts? |
| **W15** | Can an unpackaged app turn off the capture border? |
| **W16** | Is an HEVC encoder present on the test machines? |
| **W17** | Glitch soak: thirty minutes of a mix under CPU load, a GPU H.264 encode and the UI running, counted by `glitch` and explained by a WPR trace. Before M4 a stand-in process takes the UI's place. |
| **W18** | Does a test-signed ARM64 driver load in Windows 11 on Arm under Parallels with Secure Boot off? |
| **W19** | After a driver update, a driver reinstall and a Windows feature update, is a saved output found again by ID, stable ID or name? |
| **W20** | Can the driver add and remove endpoints at the app's request while other devices keep playing; does a device re-created with the same reference string keep its endpoint ID, and does a width change bring back a stale format; how evenly does the timer-driven position run under load? |
| **W21** | Renaming a device: does changing the interface friendly name reach apps, or must the endpoint be re-created, and what happens to its ID? |
| **W22** | Can a standard user's process send the private property to the driver? |
| **W23** | Does an attestation-signed driver — first a third-party one, confirmed attestation-signed; later, if the hardware program is joined, a preproduction-signed Tapdeck build — load on a PC where the Windows Driver Policy is in evaluation (audit events) or has moved to enforcement? |
| **W24** | Does test mode bypass an enforcing Windows Driver Policy, and does removing the policy with `CiTool.exe --remove-policy` (July 2026 update or later; manual removal with Secure Boot off before that) work on a development PC as documented [driver-policy-support]? |
| **W25** | Does the audio engine accept a shared-mode endpoint wider than eight channels at all, and do OBS and Zoom read an 8-channel device with its four pairs apart? |
| **W26** | VB-CABLE on a current Windows 11 PC with Secure Boot on: how is it signed, does it still load once the Windows Driver Policy enforces, which widths work in shared mode, and does name-based pairing hold? |
| **W27** | Only while option D is considered: capture plus render in C# for thirty minutes while another thread allocates heavily and forces collections. |
| **W28** | Does the WinRT encoding pipeline, given a profile with several audio tracks, write them all into an MP4? |
| **W29** | Which endpoint do the keyboard's volume keys and a headset's own buttons change, and are those changes reported to Tapdeck? |
| **W30** | Does `MinUpdateInterval` give steady frames at 60 and 120 fps, and do frames stop when nothing on screen changes? |
| **W31** | With screenshot and screen recording access turned off in the privacy settings, can an unpackaged app still capture a window or display by handle, and what does it get? |
| **W32** | Where does a new notification area icon start on Windows 11, and does `Shell_NotifyIconGetRect` tell when it is in the overflow? |
| **W33** | When the user changes one side's default format in Sound settings while the other side streams, what does the driver see and what do apps on each side get? |
| **W34** | During a Zoom call reading a cable, with Windows' default ducking: does the duck trigger when the call's communication stream is on the cable rather than on the default communication device, are Tapdeck's own streams and the apps it captures lowered, and where in the chain? |
| **W35** | Do Zoom and Teams move a cable's capture volume when they adjust the microphone automatically? |
| **W36** | When a captured app exits or restarts, does its stream report an error, deliver silence or stop? |
| **W37** | Does process loopback capture protected playback (a streaming service in Edge, Spotify), or return silence? `platform-limits.md` has the same question open for macOS. |
| **W38** | Does setting the process's preferred UI languages at startup bring the folder picker and message boxes into the chosen language, and does the UI's language setting pick the Japanese or Chinese glyph forms? |
| **W39** | Which keeps a Tapdeck device free of a second volume: a driver volume control it ignores, or resetting the endpoint whenever it changes? |

## Decisions for the user

1. **Stack**: C++ engine with a C# UI (recommended), or C# throughout if the first week's
   collector soak passes.
2. **Oldest Windows**: build 26100 and later. Windows 10 Home and Pro reached the end of
   support on 2025-10-14, and its final release, 22H2 (build 19045), is below process
   loopback's documented minimum, build 20348 [win10-lifecycle] [win10-release-info]
   [process-loopback-params]. Windows 11 Home and Pro versions up to and including 24H2 are out
   of servicing — 24H2 ended on 2026-10-13 — so consumer PCs run 25H2 or 26H2, which share
   24H2's base, or 26H1 (build 28000), which ships only on new devices sold since early 2026
   and has a base of its own [win11-release-info]; 24H2 stays in servicing for Enterprise and
   Education until October 2027 [win11-lifecycle] [win11-ent-lifecycle]. From build 26100 the
   stable endpoint ID and every capture API used here exist [stable-id]
   [process-loopback-params] [wgc-border]; an endpoint can still lack a stable ID, so device
   matching keeps its fallbacks.
3. **A Windows machine**: a real x64 PC, required from M0; Parallels Desktop on the Mac in
   addition, for functional and UI work, is optional.
4. **The driver**: after M0's paper check and, for attestation signing, W23 — stay with
   third-party cables, build Tapdeck's driver for the developer's own use only, or register a
   business and pay for an EV certificate and possibly HLK testing.
5. **The app's signing**: an individual code signing certificate before the first public build,
   or unsigned previews that Smart App Control blocks.
6. **Merging `feature/zh-cn` into `feature/windows`**, so the Windows app starts with the
   Simplified Chinese strings.

Out of scope: AirPlay, ASIO, exclusive-mode streams, and sending audio over the network.

## Sources

Every bracketed label in the text links to its source; the addresses are kept at the end of
this file's Markdown, grouped by topic.

<!-- Audio capture and devices -->

[process-loopback-params]: https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ns-audioclientactivationparams-audioclient_process_loopback_params
[process-loopback-mode]: https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ne-audioclientactivationparams-process_loopback_mode
[activate-async]: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nf-mmdeviceapi-activateaudiointerfaceasync
[app-loopback-sample]: https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/
[app-loopback-source]: https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/ApplicationLoopback/cpp/LoopbackCapture.cpp
[ms-qa-mixformat]: https://learn.microsoft.com/en-us/answers/questions/1125409/loopbackcapture-activateaudiointerfaceasync-with-v
[teams-issue]: https://github.com/microsoft/Windows-classic-samples/issues/414
[obs-plugin-main]: https://github.com/obsproject/obs-studio/blob/master/plugins/win-wasapi/plugin-main.cpp
[obs-forum-mute]: https://obsproject.com/forum/threads/how-do-i-mute-audio-from-a-certain-window-while-still-making-it-so-you-can-hear-in-the-recording.163301/
[obs-forum-volume]: https://obsproject.com/forum/threads/how-to-make-obs-capture-full-windows-volume-despite-muted.162766/
[naudio-builder]: https://github.com/naudio/NAudio/blob/main/src/NAudio.Wasapi/WasapiRecorderBuilder.cs
[loopback-recording]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
[initialize]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize
[vaneerde-loopback]: https://matthewvaneerde.wordpress.com/2008/12/16/sample-wasapi-loopback-capture-record-what-you-hear/
[capture-getbuffer]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer
[streamflags]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants
[clock-adjustment]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclockadjustment-setsamplerate
[iaudioclient3]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient3-initializesharedaudiostream
[invalid-device]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/recovering-from-an-invalid-device-error
[mmcss]: https://learn.microsoft.com/en-us/windows/win32/api/avrt/nf-avrt-avsetmmthreadcharacteristicsw
[mmcss-overview]: https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service
[device-state]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-state-xxx-constants
[register-session-notification]: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessionmanager2-registersessionnotification
[device-formats]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats
[endpoint-ids]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/endpoint-id-strings
[stable-id]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-stableid
[friendly-name]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-device-friendlyname
[form-factor]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-formfactor
[notification-client]: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient
[enumerator]: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immdeviceenumerator
[session-manager2]: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nn-audiopolicy-iaudiosessionmanager2
[ducking-disable]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/disabling-the-ducking-experience
[audio-sessions]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/audio-sessions
[stream-attenuation]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/stream-attenuation
[ducking-preference]: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessioncontrol2-setduckingpreference
[device-roles]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-roles
[stream-latency]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getstreamlatency
[process-times]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes
[session-control2]: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nn-audiopolicy-iaudiosessioncontrol2
[session-notification]: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nn-audiopolicy-iaudiosessionnotification
[simple-audio-volume]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-isimpleaudiovolume
[eartrumpet-session]: https://github.com/File-New-Project/EarTrumpet/blob/master/EarTrumpet/DataModel/WindowsAudio/Internal/AudioDeviceSession.cs
[eartrumpet-policy]: https://github.com/File-New-Project/EarTrumpet/blob/master/EarTrumpet/DataModel/WindowsAudio/Internal/AudioPolicyConfigService.cs
[soundswitch]: https://github.com/Belphemur/SoundSwitch
[audiodevicecmdlets]: https://github.com/frgnca/AudioDeviceCmdlets
[endpoint-volume]: https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudioendpointvolume
[endpoint-volume-controls]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/endpoint-volume-controls
[hardware-support]: https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nf-endpointvolume-iaudioendpointvolume-queryhardwaresupport
[priority-inversion]: https://learn.microsoft.com/en-us/windows/win32/procthread/priority-inversion
[container-id]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-device-containerid
[bluetooth-le-audio]: https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/bluetooth-low-energy-audio
[endpoint-volume-callback]: https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudioendpointvolumecallback
[bluetooth-classic-audio]: https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/bluetooth-classic-audio
[get-aumid]: https://learn.microsoft.com/en-us/windows/win32/api/appmodel/nf-appmodel-getapplicationusermodelid
[image-name]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew
[audio-resampler]: https://learn.microsoft.com/en-us/windows/win32/medfound/audioresampler
[privacy-mic]: https://support.microsoft.com/en-us/windows/privacy/windows-camera-microphone-and-privacy
[globalization-languages]: https://learn.microsoft.com/en-us/uwp/api/windows.system.userprofile.globalizationpreferences.languages
[set-process-languages]: https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-setprocesspreferreduilanguages
[render-releasebuffer]: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiorenderclient-releasebuffer
[ui-languages]: https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-getuserpreferreduilanguages
[wpr]: https://learn.microsoft.com/en-us/windows-hardware/test/wpt/windows-performance-recorder

<!-- Recording -->

[aac-encoder]: https://learn.microsoft.com/en-us/windows/win32/medfound/aac-encoder
[mp3-encoder]: https://learn.microsoft.com/en-us/windows/win32/medfound/mp3-audio-encoder
[supported-codecs]: https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/supported-codecs
[wmcodecdsp]: https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/wmcodecdsp.h
[aiff-spec]: https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/AIFF/Docs/AIFF-1.3.pdf
[waveformatextensible]: https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible
[mp4-sink-create]: https://learn.microsoft.com/en-us/windows/win32/api/mfidl/nf-mfidl-mfcreatempeg4mediasink
[video-processor]: https://learn.microsoft.com/en-us/windows/win32/medfound/video-processor-mft
[wgc-frame-time]: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframe.systemrelativetime
[naming-files]: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
[h264-encoder]: https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder
[hevc-encoder]: https://learn.microsoft.com/en-us/windows/win32/medfound/h-265---hevc-video-encoder
[wgc]: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture
[wgc-interop]: https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow
[wgc-interop-monitor]: https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createformonitor
[wgc-min-update]: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval
[set-audio-tracks]: https://learn.microsoft.com/en-us/uwp/api/windows.media.mediaproperties.mediaencodingprofile.setaudiotracks
[transcode-api]: https://learn.microsoft.com/en-us/windows/win32/medfound/transcode-api
[ffmpeg-legal]: https://ffmpeg.org/legal.html
[wgc-cursor]: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.iscursorcaptureenabled
[wgc-border]: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.isborderrequired
[display-affinity]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity
[desktop-dup]: https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api

<!-- App shell, signing and deployment -->

[notifyicondata]: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw
[notify-icon-rect]: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyicongetrect
[taskbar]: https://learn.microsoft.com/en-us/windows/win32/shell/taskbar
[sf-symbols]: https://developer.apple.com/sf-symbols/
[segoe-fluent-icons]: https://learn.microsoft.com/en-us/windows/apps/design/style/segoe-fluent-icons-font
[uninstall-key]: https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key
[notification-area]: https://learn.microsoft.com/en-us/windows/win32/shell/notification-area
[taskbar-support]: https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows
[winui-tray-issue]: https://github.com/microsoft/WindowsAppSDK/issues/713
[smartscreen]: https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation
[smart-app-control-faq]: https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions
[policy-csp-privacy]: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy
[smart-app-control]: https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview
[sslcom-iv]: https://www.ssl.com/products/software-integrity/code-signing/iv/
[artifact-signing-quickstart]: https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart
[artifact-signing-faq]: https://learn.microsoft.com/en-us/azure/artifact-signing/faq
[msix-signing]: https://learn.microsoft.com/en-us/windows/msix/package/signing-package-overview
[wasdk-release-channels]: https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-channels
[wasdk-self-contained]: https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps
[prism]: https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation
[win10-lifecycle]: https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro
[win11-release-info]: https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information
[win11-ent-lifecycle]: https://learn.microsoft.com/en-us/lifecycle/products/windows-11-enterprise-and-education
[win10-release-info]: https://learn.microsoft.com/en-us/windows/release-health/release-information
[win11-lifecycle]: https://learn.microsoft.com/en-us/lifecycle/products/windows-11-home-and-pro

<!-- Languages and toolchains -->

[swift-windows]: https://www.swift.org/install/windows/
[swift-platforms]: https://www.swift.org/platform-support/
[swift-foundation]: https://github.com/swiftlang/swift-foundation
[corelibs-foundation]: https://github.com/swiftlang/swift-corelibs-foundation
[swift-winrt]: https://github.com/thebrowsercompany/swift-winrt
[swift-windowsappsdk]: https://github.com/thebrowsercompany/swift-windowsappsdk
[apple-os-unfair-lock]: https://developer.apple.com/documentation/os/os_unfair_lock
[libm-accuracy]: https://hal.science/hal-03141101
[swift-winui]: https://github.com/thebrowsercompany/swift-winui
[arc-windows-release]: https://techcrunch.com/2024/04/30/the-browser-company-releases-arc-for-windows/
[arc-windows]: https://speakinginswift.substack.com/p/swift-meet-winrt
[gc-latency]: https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/latency
[dotnet-com-generator]: https://learn.microsoft.com/en-us/dotnet/standard/native-interop/comwrappers-source-generation
[naudio-release]: https://github.com/naudio/NAudio/releases/tag/v3.0.0
[wgc-csharp-sample]: https://github.com/microsoft/Windows.UI.Composition-Win32-Samples/tree/master/dotnet/WPF/ScreenCapture
[cswin32]: https://github.com/microsoft/CsWin32
[clangsharp]: https://github.com/dotnet/ClangSharp
[windows-rs]: https://github.com/microsoft/windows-rs
[qt-licensing]: https://doc.qt.io/qt-6/licensing.html
[juce-licence]: https://github.com/juce-framework/JUCE/blob/master/LICENSE.md
[wdk-nuget]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install-the-wdk-using-nuget
[runner-images]: https://github.com/actions/runner-images
[runner-images-vs2026]: https://github.com/actions/runner-images/issues/14017
[win11-arm-mac]: https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips
[parallels-vbs]: https://kb.parallels.com/en/129497

<!-- The driver and its signing -->

[ms-qa-endpoint]: https://learn.microsoft.com/en-au/answers/questions/1622324/how-to-use-iaudioendpoint-and-connect-it-to-audio
[acx-overview]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/acx-audio-class-extensions-overview
[acx-circuits]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/acx-device-enumeration
[sysvad-bthhfp]: https://github.com/microsoft/Windows-driver-samples/blob/main/audio/sysvad/BthhfpDevice.cpp
[simpleaudio-tone]: https://github.com/microsoft/Windows-driver-samples/blob/main/audio/simpleaudiosample/Source/Utilities/ToneGenerator.cpp
[acx-tone]: https://github.com/microsoft/Windows-driver-samples/blob/main/audio/Acx/Samples/Common/ToneGenerator.cpp
[sysvad-readme]: https://github.com/microsoft/Windows-driver-samples/blob/main/audio/sysvad/README.md
[dynamic-subdevices]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/dynamic-audio-subdevices
[friendly-names]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/friendly-names-for-audio-endpoint-devices
[usb-audio-2]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/usb-2-0-audio-drivers
[oem-format]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/pkey-audioengine-oemformat
[audio-property-requests]: https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-property-requests
[ikscontrol]: https://learn.microsoft.com/en-us/windows/win32/coreaudio/using-the-ikscontrol-interface-to-access-audio-properties
[ioopendeviceregistrykey]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-ioopendeviceregistrykey
[tracelogging]: https://learn.microsoft.com/en-us/windows/win32/tracelogging/trace-logging-portal
[hvci]: https://learn.microsoft.com/en-us/windows-hardware/drivers/driversecurity/implement-hvci-compatible-code
[setupdi-createdeviceinfo]: https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdicreatedeviceinfow
[swdevicecreate]: https://learn.microsoft.com/en-us/windows/win32/api/swdevice/nf-swdevice-swdevicecreate
[swdevice-lifetime]: https://learn.microsoft.com/en-us/windows/win32/api/swdevice/nf-swdevice-swdevicesetlifetime
[pnputil]: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax
[driver-isolation-blog]: https://techcommunity.microsoft.com/blog/hardware-dev-center/driver-isolation-ruleset-changes-for-whcp-and-attestation-submissions/4461580
[infverif-h]: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/infverif_h
[driver-signing-policy]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-
[cert-deprecation]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/deprecation-of-software-publisher-certificates-and-commercial-release-certificates
[driver-policy-blog]: https://techcommunity.microsoft.com/blog/windows-itpro-blog/advancing-windows-driver-security-removing-trust-for-the-cross-signed-driver-pro/4504818
[driver-policy-support]: https://support.microsoft.com/en-us/windows/hardware/drivers/the-windows-driver-policy
[testsigning]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/the-testsigning-boot-configuration-option
[code-signing-attestation]: https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-attestation
[code-signing-reqs]: https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-reqs
[driver-signing-offerings]: https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings
[preprod-install]: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/preproduction-driver-signing-and-install
[hlk-prereqs]: https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/windows-hlk-prerequisites
[custom-kernel-signers]: https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/custom-kernel-signers
[hardware-program-register]: https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/hardware-program-register
[hw-verification-blog]: https://techcommunity.microsoft.com/blog/hardware-dev-center/action-required-account-verification-for-windows-hardware-program-begins-october/4455452
[csbr]: https://cabforum.org/working-groups/code-signing/requirements/
[sslcom-ev]: https://www.ssl.com/products/software-integrity/code-signing/ev/
[sslcom-sole-prop]: https://www.ssl.com/products/software-integrity/code-signing/ev-sole-proprietor/
[sslcom-sole-guide]: https://www.ssl.com/guide/sole-proprietor-ev-application/
[wotrus-ev]: https://www.wosign.com/Products/ev_codesigning_pre.htm
[wotrus-digicert-ev]: https://www.wosign.com/Products/digicert_CodeSigning_EV.htm
[wotrus-article]: https://www.wosign.com/wenda/5103.html
[sectigo-f2f]: https://www.sectigo.com/faqs/detail/Face-to-Face-Verification-Form-for-Extended-Validation-EV-and-Code-Signing-Certificates
[vbcable]: https://vb-audio.com/Cable/
[vb-licensing]: https://vb-audio.com/Services/licensing.htm
[voicemeeter]: https://vb-audio.com/Voicemeeter/index.htm
[vad-repo]: https://github.com/VirtualDrivers/Virtual-Audio-Driver
[vad-issue15]: https://github.com/VirtualDrivers/Virtual-Audio-Driver/issues/15
[sar]: https://github.com/eiz/SynchronousAudioRouter
[scream]: https://github.com/duncanthrax/scream
