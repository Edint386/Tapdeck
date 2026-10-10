# Third-party material

Tapdeck contains no third-party code, libraries, fonts, models or data. It uses only
frameworks that ship with macOS:

| Framework | Used for |
|---|---|
| Core Audio, AudioToolbox (AUHAL) | Process taps, device input and output, and the virtual device driver (`AudioServerPlugIn`) |
| AVFoundation, Core Media | Sample rate conversion, and writing audio files and screen recordings |
| ScreenCaptureKit | Screen recording |
| SwiftUI, AppKit, Combine | The user interface |
| Core Foundation, Dispatch, the C library | The driver |

Nothing is bundled, so there is nothing to credit inside the app.

## The virtual device driver

`Driver/TapdeckDriver.c` was written for Tapdeck against Apple's documented
`AudioServerPlugIn` interface (`CoreAudio/AudioServerPlugIn.h`). It is not derived from
Apple's NullAudio sample code or from BlackHole (GPL-3.0), and no code was copied from
either.

This was checked on 2026-10-07 by comparing the file line by line with BlackHole's
`BlackHole.c`, which itself descends from NullAudio. Apart from what the interface
dictates — the property constants in `case` labels and the standard assignments to
`outData` — the two files share six lines: four system `#include`s and two one-line Core
Foundation idioms. No comments or blocks are shared. One naming convention,
`kObjectID_PlugIn` for the plug-in object, is the same as in Apple's sample.

## Building

Building needs Xcode or Apple's Command Line Tools. Nothing else is downloaded or bundled.
