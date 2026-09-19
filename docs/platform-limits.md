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
| Set a device's own volume even when it is not the Mac's output | Verified for MacBook Pro Speakers; Unknown for AirPlay and Bluetooth | `kAudioDevicePropertyVolumeScalar` is settable on the speakers. Virtual devices have no volume of their own; HDMI outputs often have none. Test T4. |
| Make a device louder than its own maximum | Not possible cleanly | Digital audio has a ceiling (0 dBFS). With the device at 100 %, anything boosted further in software is cut off: that is the distortion. Only *perceived* loudness can rise, through compression, limiting or loudness normalisation. |
| Volume keys control a Tapdeck mix | Only indirectly | The keys change the volume of the Mac's current output device and nothing else. |

This is why earlier versions distorted without being loud: Tapdeck boosted the
signal digitally (+7.1 dB on the way to the speakers in the saved Main mix), cut
it off at 0 dBFS, and only then did the speakers' own volume turn it down.

## AirPlay

| Want | Status | Why |
|---|---|---|
| Choose an AirPlay receiver from inside the app for the Mac's output | Not possible with public API | On macOS, `AVRoutePickerView` routes only an `AVPlayer` — its header: "The player for which to perform routing operations". `AVCustomRoutingController` is unavailable on macOS. The Core Audio AirPlay device exposes no list of receivers. The receiver is chosen in Control Center or Sound settings. |
| Make AirPlay the output from the app, once a receiver has been used | Unknown | Setting the Mac's output device is allowed; whether that connects the receiver is test T2. |
| Stream to a receiver without macOS | Not realistic | It means implementing the AirPlay protocol itself, pairing and encryption included, which is what Airfoil does. Private frameworks are not used: they change without notice. |
| Route the mix through `AVPlayer` so the route picker applies | Impractical | `AVPlayer` plays media items, not a live callback. The mix would have to be packaged as a live stream, adding seconds of delay. Not planned. |
| Remove AirPlay's delay | Not possible | The receiver buffers about 2 s by design. Other outputs can only be delayed to match. |
| Know the delay without measuring | Not possible | The device reported 0 ms of latency while playing about 2 s late (Verified). |
| Measure the delay automatically | Possible in principle, Unknown in practice | Play a test signal to the output, record it with the Mac's microphone, find the offset. Room noise and the microphone permission are the risks. |

## Tests still to run (AirPlay receiver switched on)

- **T1** With the AirPlay device present but not the Mac's output, open it as a Tapdeck output and record the error.
- **T2** Set the Mac's output to the AirPlay device from Tapdeck: does the receiver connect and play?
- **T3** After T2, set the Mac's output back to the speakers: does Tapdeck's AirPlay output keep playing?
- **T4** Is the AirPlay device's own volume readable and settable?

## What the design does with this

1. **One volume per place.** An output's fader is the device's own volume, where the device has one, so turning it up really is louder and never distorts. Every other fader only turns down. Each output ends in a limiter instead of a hard cut, and its meter shows when the limiter works.
2. **Tapdeck owns the routing.** When a mix has an AirPlay output, Tapdeck makes AirPlay the Mac's output while the mix runs, replaces the original system audio so nothing plays twice, and puts everything back when the mix stops. (Depends on T2.)
3. **The receiver is chosen where macOS allows it.** Tapdeck opens Sound settings and picks up the AirPlay device as soon as it appears.
4. **Candidate:** measure wireless delays with the microphone instead of guessing them.
