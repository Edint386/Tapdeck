# Tapdeck

Audio routing and recording for macOS — the things Loopback and Audio Hijack do,
built on Core Audio's modern APIs.

## What it is for

macOS gives every application one output and lets you pick one input. That is
fine until you want audio to go two places at once, or want to combine sources
that the operating system keeps apart:

- **Share your computer's audio on a call.** Zoom lets you share your
  microphone. It does not let you share the music, the video, or the other
  person's voice coming out of your speakers, because those are an *output* and
  Zoom wants an *input*. Tapdeck mixes them together and offers the result as an
  input device, so Zoom sees one microphone carrying both.
- **Record one app without recording everything.** System audio capture gets
  you the whole machine — notifications, other calls, whatever else is playing.
  Tapdeck can take one application's audio on its own.
- **Send different mixes to different places.** Your headphones want the full
  mix; the recording should not include the notification sounds; the stream
  wants the game but not the voice chat. Each destination gets its own device.

The common thread is that audio inside a Mac normally flows one way, from apps
to one output. Tapdeck lets you tap it, combine it, and present the result
wherever another app expects an input.

## How it works

```
app audio (process tap) ┐
all system audio        ├→ [convert] → [ring buffer] → sum → virtual device
microphone / interface  ┘                                         │
                                        Zoom / OBS read it as a microphone
```

Three pieces:

1. **Per-app capture** uses Core Audio process taps (macOS 14.2+). No virtual
   audio driver and no kernel extension are involved.
2. **The virtual devices** are an `AudioServerPlugIn` — a user-space plug-in, so
   SIP stays on. They loop back: whatever is played into the output side can be
   read from the input side.
3. **The mixer** combines sources and feeds one virtual device.

Screen recording sits on top of this rather than beside it.

## Status

| Piece | State |
|---|---|
| Per-app audio capture | Working. Measured 113 dB of separation between two apps playing at once. |
| Virtual audio devices | Working. Up to 8, named, created and removed live. |
| Mixer | Working. Verified with zero discontinuities across a three-source mix. |
| Presets | Working. |
| Menu bar item | Working, but a full menu bar can leave no room for it (see below). |
| Screen recording | Working. Audio can come from ScreenCaptureKit or from the mixer. |

## Install

```
./install.sh                 # builds and installs into /Applications
sudo ./install-driver.sh     # once, to register the virtual devices
```

### About signing

`install.sh` creates a self-signed certificate named `Tapdeck Local` on first
run. This matters more than it sounds: an ad-hoc signature changes on every
build, macOS treats each build as a different application, and every granted
permission — microphone, screen recording, audio capture — resets. With a fixed
certificate the designated requirement stays constant:

```
designated => identifier "dev.kosuke.Tapdeck" and certificate root = H"68b7190f…"
```

Distribution would need a Developer ID and notarisation. This is for running on
your own machine.

## Development

```
./build.sh                   # build without installing
./Driver/build-driver.sh     # build the driver only
swift tools/make-icon.swift  # regenerate the icon
```

`build/tapproof` is a command line harness that drives the same engine:

```
./build/tapproof list                    # processes Core Audio can see
./build/tapproof devices                 # audio devices
./build/tapproof virtual Meetings Stream # replace the virtual devices
./build/tapproof rec Chrome 10 out.wav   # record one app for 10s
./build/tapproof mix 1234 5              # send an app through the mixer
./build/tapproof loopback 4              # check a virtual device round-trips
```

## Implementation notes

Each of these cost real time to find, and none of them announced itself.

### Process taps are silent without NSAudioCaptureUsageDescription

Core Audio process taps are gated by TCC's `kTCCServiceAudioCapture`. The
Info.plist key that goes with it is `NSAudioCaptureUsageDescription`.

Without it, `AudioHardwareCreateProcessTap` **still succeeds** — it just
delivers silence forever. No error, no prompt, nothing in the log. The same code
run from a command line tool worked, because that inherited its parent's
permission, which made it look like an app bug.

### The tap's reported sample rate can be wrong

What reaches the IOProc is the aggregate device's input stream, and the
aggregate follows the clock of its main sub-device — the default output device.
So `kAudioTapPropertyFormat` can disagree with reality.

Measured: the built-in speakers ran at 44100 Hz while the tap reported 48000 Hz.
Trusting the tap pitch-shifts every recording by 8.8%, turning 440 Hz into
479 Hz. Read `kAudioDevicePropertyNominalSampleRate` from the aggregate instead.

### Tap buffers are interleaved

`AVAudioFile` and `AVAudioEngine` both assume the opposite. A mismatch makes
every `write(from:)` throw and leaves a file containing only a header.
`ProcessTap` normalises to non-interleaved Float32 before handing anything on.

### Don't point a tap's clock at the output device

Matching the tap's clock to the mixer's output removes the need to resample,
which seems like the right move. It also stops the tap from hearing anything
that is not already flowing to that device — measured as complete silence.

### Ring buffers need a cushion

Sources and output run on different clocks, so matching their rates still leaves
their phase unmatched. Reading without a cushion keeps the buffer near empty and
every wobble punches a gap in the waveform. It shows up as the overall level
being right while one frequency collapses.

### The driver is not hosted by coreaudiod

It runs inside `com.apple.audio.Core-Audio-Driver-Service.helper`, which is
sandboxed far more tightly. It cannot read any path an unprivileged app can
write, so configuration files never reach it — again with no error and no denial
in the log. The device list travels through a Core Audio **custom property**
instead, which stays inside the HAL.

### Real-time paths must not take a lock the disk can hold

`DoIOOperation` and `GetZeroTimeStamp` run on the real-time thread. Any lock
they take must never be held by something doing file I/O, or the audio breaks up
waiting for the disk.

### SwiftUI's MenuBarExtra did not work here

In this setup — a bundle built with `swiftc`, alongside a `Window` scene — it
created no status item even in its simplest form. `NSStatusItem` is used
directly instead.

### A notched display can have no room for a status item

Status items can only occupy the strip to the right of the notch. Measured on an
1800 pt display, the notch took 790–1010, leaving 1010–1800. Once other apps
fill that, macOS allocates no slot and pushes the item's window off screen (to
y = -22) without reporting anything. `MenuBarController` detects this and says
so in the UI.

### ffmpeg's avfoundation capture is not a measuring instrument

While verifying the mixer, a 440 Hz tone came back at -32.6 dB instead of
-21.1 dB, with phase jumps every 512 frames. The ring buffer, the converter and
the tap all measured clean. Recording the same signal through the app's own
AUHAL gave -21.1 dB with zero discontinuities. The capture tool was dropping
blocks. The app has a monitor recorder now so measurements do not depend on it.

## Permissions

- **Audio capture** — for process taps, on first use.
- **Microphone** — for reading any input device, including Tapdeck's own.
- **Screen recording** — for the recording tab. macOS quits the app once after
  this is granted; launch it again.
