# Tapdeck — project context

Audio routing, mixing and recording for macOS, in the spirit of Loopback and
Audio Hijack, built on current Core Audio APIs. See `README.md` for the user
view and the list of hard-won implementation notes; this file is for resuming
work.

## Conventions

- Everything in the repository is written in English: code, comments, UI text,
  commit messages. Conversation with the user is in Japanese.
- Work on task branches (`feat/…`, `fix/…`, `chore/…`, `refactor/…`), commit at
  each working step with conventional messages (`feat(mixer): …`), merge back
  to `main` with `--no-ff`, and tag a version when a coherent set of changes
  lands (patch for small steps, minor for significant interface or feature
  changes).
- Deliver the app installed in `/Applications` with the stable signing
  identity, never as a build-directory prototype.
- Verify audio behaviour by measurement, not by ear: `tapproof` captures through
  the app's own AUHAL path and the analyses read samples directly. ffmpeg's
  avfoundation capture drops blocks and is not trustworthy for this.

## Stack

- Swift 5 language mode, SwiftUI + AppKit, built with `swiftc` from
  `build.sh` (Xcode's SDK if installed). No Xcode project.
- Core Audio: process taps (macOS 14.2+), AUHAL for device input and output,
  aggregate devices for taps.
- ScreenCaptureKit + AVAssetWriter for screen recording.
- The virtual device driver is a C `AudioServerPlugIn` in `Driver/`.
- Minimum macOS 15. Developed on macOS 26, Apple Silicon.

## Architecture

### Engine (`Sources/Engine`) — no UI framework dependencies

| File | Role |
|---|---|
| `CoreAudioSupport.swift` | Property helpers, `ca()` status checking, `AVAudioFormat.discrete` for formats above two channels |
| `AudioDevice.swift` | Device enumeration with channel counts and sample rate |
| `AudioProcess.swift` | Processes Core Audio considers audio-active; names via NSRunningApplication, bundle ID, then libproc |
| `ProcessTap.swift` | One process tap plus the private aggregate device that reads it; normalises to non-interleaved Float32 and corrects the reported sample rate |
| `DeviceIO.swift` | `DeviceOutput` and `DeviceInput`, both driving an AUHAL directly |
| `FormatConverter.swift` | AVAudioConverter wrapper used when a source's rate differs from the mix |
| `AudioRingBuffer.swift` | Per-source and per-output buffering with a priming cushion, channel offsets on read |
| `Mixer.swift` | One mix: sources, outputs, attach/detach, the real-time render and fan-out to secondary outputs |
| `RoutingGraph.swift` | Feedback-loop detection across running mixes |
| `MuxedRecorder.swift` | Screen video plus device audio into a .mov, one AAC track per channel pair |
| `VirtualDeviceConfiguration.swift` | The virtual device list, pushed to the driver through a custom property |

### App (`Sources/App`)

| File | Role |
|---|---|
| `TapdeckApp.swift` | Scenes, app delegate (pushes virtual devices at launch, installs the menu bar item) |
| `AppModels.swift` | Shared owner of the models, reachable from AppKit |
| `MixerModel.swift` | Library of mixes, device and application lists, feedback checks |
| `MixSession.swift` | One mix as the UI sees it, wrapping a `Mixer` |
| `MixLibrary.swift` | Saved mixes, and migration from the older single-mixer and preset storage |
| `MixerConfiguration.swift` | Codable source representation shared by saved mixes |
| `MixerPanelView.swift` | Sidebar of mixes and the mix editor |
| `MenuBarController.swift`, `MenuBarPanelView.swift` | NSStatusItem and its popover |
| `AudioEngineModel.swift`, `AudioPanelView.swift` | Virtual device management and diagnostics |
| `Recorder.swift`, `ContentView.swift` | Screen recording model and its tab |

### Driver (`Driver/TapdeckDriver.c`)

Loopback devices, up to 8, each with up to 16 channels. The device list arrives
through the custom property `'tpdv'` on the plug-in object. Object IDs come from
a counter and are never reused while Core Audio runs. The real-time IO path
takes no locks.

### Command line harness (`Sources/CLI/main.swift`)

`tapproof` exercises the engine without the app: capture, mixing to several
outputs, tones on single channels, multitrack muxing, sample rate changes and
the routing graph tests.

## Commands

```sh
./build.sh                          # build Tapdeck.app, build/tapproof, Tapproof.app
./install.sh                        # build and install into /Applications
sudo ./install-driver.sh            # build and install the HAL driver (restarts Core Audio)
./Driver/build-driver.sh            # driver only
./build/tapproof                    # list harness commands
./build/tapproof graphtest          # routing graph tests (no devices needed)
./build/tapproof muxtest out.mov    # multitrack recording test (no devices needed)
```

## Things that will bite

The README's implementation notes are the full list with measurements. The ones
most likely to recur:

- Process taps return silence, not an error, without
  `NSAudioCaptureUsageDescription` in Info.plist.
- `kAudioTapPropertyFormat`'s sample rate can be wrong; read it from the
  aggregate device.
- The driver runs in `com.apple.audio.Core-Audio-Driver-Service.helper`, which
  cannot read files the app can write.
- `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil
  above two channels.
- A command line tool cannot show TCC prompts; anything reading an input device
  must be verified from an app bundle.
- SwiftUI `MenuBarExtra` created no status item in this build setup.
