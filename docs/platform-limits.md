# What macOS lets Tapdeck do

Design starts from this map. Every item says whether it is possible, why, and how
sure that is. Features are built only in the possible area; the unknowns have a
test attached, and the impossible items say what stands in the way so that the
design routes around them instead of trying its luck.

| Mark | Meaning |
|---|---|
| **Verified** | Measured or exercised on this machine |
| **Documented** | Stated by Apple's SDK headers or documentation, not exercised here |
| **Unknown** | Needs the test named in the table |
| **Not possible** | Blocked; the reason is given |

## Capture

| Want | Status | Why |
|---|---|---|
| One app's audio on its own | Verified | Core Audio process taps (macOS 14.2+). 113 dB separation measured between two apps. |
| All system audio except chosen apps | Verified | A tap can exclude a list of processes. |
| Silence the app's own output while Tapdeck plays it ("replace the original") | Verified | `CATapMuteBehavior.mutedWhenTapped`. The original comes back within 1.5 s if Tapdeck is killed. |
| Change another app's own volume setting | Not possible | No API sets another process's volume. Tapdeck scales its copy of the audio and can silence the original. |
| Capture DRM-protected playback | Unknown | Not tested. Test: tap a protected stream and look for silence. |

## Devices and routing

| Want | Status | Why |
|---|---|---|
| Virtual input/output devices | Verified | An `AudioServerPlugIn` driver; installing it needs an administrator password once. |
| Send one app straight to another device, without Tapdeck in between | Not possible | Core Audio has no setting for another app's output device; each app picks its own, and most follow the Mac's output. Tapdeck gets the same result by replacing the original and playing the copy wherever it likes (Verified). |
| Change the Mac's output and input device | Verified settable | `kAudioHardwarePropertyDefaultOutputDevice` and `…InputDevice` report settable. Tapdeck switching them has not been exercised yet. |
| Play one mix to several devices at once | Verified | Several AUHAL outputs; secondaries resampled when rates differ. |
| Play to a device that is not the Mac's output | Verified for speakers and virtual devices; **Unknown for AirPlay** | Reported: selecting AirPlay in Tapdeck before macOS has it as the output fails. Tests T1–T3 below. |

## Volume

| Want | Status | Why |
|---|---|---|
| Set a device's own volume even when it is not the Mac's output | Verified on a loopback device (write, read back, change notification, restore) and readable on MacBook Pro Speakers, matching `osascript`'s output volume; Unknown for AirPlay and Bluetooth | `kAudioDevicePropertyVolumeScalar` is settable on both. Virtual Tapdeck devices have no volume of their own; HDMI outputs often have none. Test T4. |
| Notice volume changes made elsewhere (volume keys, menu bar) | Verified | Property listeners on the volume and mute; no polling. |
| Make a device louder than its own maximum | Not possible cleanly | Digital audio has a ceiling (0 dBFS). With the device at 100 %, anything boosted further in software is cut off: that is the distortion. Only *perceived* loudness can rise, through compression, limiting or loudness normalisation. |
| Volume keys control a Tapdeck mix | Only indirectly | The keys change the volume of the Mac's current output device and nothing else. |

This is why earlier versions distorted without being loud: Tapdeck boosted the
signal digitally (+7.1 dB on the way to the speakers in the saved Main mix), cut
it off at 0 dBFS, and only then did the speakers' own volume turn it down.

## AirPlay

| Want | Status | Why |
|---|---|---|
| Choose an AirPlay receiver from inside the app for the Mac's output | Not possible with public API | On macOS, `AVRoutePickerView` routes only an `AVPlayer` — its header: "The player for which to perform routing operations". `AVCustomRoutingController` is unavailable on macOS. The Core Audio AirPlay device exposes no list of receivers. The receiver is chosen in Control Center or Sound settings. |
| Make AirPlay the output from the app, once a receiver has been used | Unknown — implemented, awaiting T2 | Setting the Mac's output device is allowed; whether that connects the receiver is test T2. Tapdeck now does this while a mix plays to AirPlay and restores the previous output afterwards, or at the next launch after a crash. |
| Stream to a receiver without macOS | Not realistic | It means implementing the AirPlay protocol itself, pairing and encryption included, which is what Airfoil does. Private frameworks are not used: they change without notice. |
| Route the mix through `AVPlayer` so the route picker applies | Impractical | `AVPlayer` plays media items, not a live callback. The mix would have to be packaged as a live stream, adding seconds of delay. Not planned. |
| Remove AirPlay's delay | Not possible | The receiver buffers about 2 s by design. Other outputs can only be delayed to match. |
| Know the delay without measuring | Not possible | The device reported 0 ms of latency while playing about 2 s late (Verified). |
| Measure the delay automatically | Possible in principle, Unknown in practice | Play a test signal to the output, record it with the Mac's microphone, find the offset. Room noise and the microphone permission are the risks. |

## More than one wireless output, and the headphone jack

| Want | Status | Why |
|---|---|---|
| Several AirPlay receivers as separate Tapdeck outputs | Not possible | Core Audio shows one AirPlay device, standing for whatever macOS is connected to at the moment, not one device per receiver (seen with one receiver; not checked with several). Separate outputs would need one device per receiver, and apps cannot connect receivers themselves. |
| Several AirPlay receivers playing the same thing | Unknown | Only if macOS itself groups them (AirPlay 2 receivers) behind that one device. Test: whether Control Center › Sound lets more than one receiver be ticked at once. |
| AirPlay and Bluetooth from one mix | Possible (not yet tried with Bluetooth here) | A Bluetooth device is an ordinary output, and one mix plays to several outputs (Verified with speakers and AirPlay). Line Up delays the faster ones. A Bluetooth headset's microphone must not be used as a source: opening it switches the headset to call quality. |
| Use the MacBook Pro's headphone jack (M1 Pro, 2021) as a stereo line input | Not possible | The jack's wiring is fixed in hardware: stereo out for headphones, and on four-pole headsets a mono microphone line. Software cannot turn an output into an input. The mono microphone line is mic-level and not meant for line signals (headset microphone support is Apple's general behaviour, not checked on this Mac). |
| Bring an external source in by wire | Possible with hardware | A USB audio interface with a line input appears as an ordinary input device and can be a source. |
| Bring a phone's or tablet's audio in without a cable | Possible in principle, Unknown here | The Mac can be an AirPlay receiver (System Settings › General › AirDrop & Handoff › AirPlay Receiver). What it receives plays on the Mac, where All system audio should capture it. Not tested. |

## Tests still to run (AirPlay receiver switched on)

- **T1** With the AirPlay device present but not the Mac's output, open it as a Tapdeck output and record the error.
- **T2** Set the Mac's output to the AirPlay device from Tapdeck: does the receiver connect and play?
- **T3** After T2, set the Mac's output back to the speakers: does Tapdeck's AirPlay output keep playing?
- **T4** Is the AirPlay device's own volume readable and settable?
- **T5** With AirPlay as the Mac's output, does a process tap still hear apps? A tap's aggregate runs on the Mac's output as its clock, and a Tapdeck virtual device was measured unable to clock one (no callbacks at all).

## What the design does with this

1. **One volume per place.** An output's fader is the device's own volume, where the device has one, so turning it up really is louder and never distorts. Every other fader only turns down. Each output ends in a limiter instead of a hard cut, and its meter shows when the limiter works.
2. **Tapdeck owns the routing.** When a mix has an AirPlay output, Tapdeck makes AirPlay the Mac's output while the mix runs, replaces the original system audio so nothing plays twice, and puts everything back when the mix stops. (Depends on T2.)
3. **The receiver is chosen where macOS allows it.** Tapdeck opens Sound settings and picks up the AirPlay device as soon as it appears.
4. **Candidate:** measure wireless delays with the microphone instead of guessing them.
