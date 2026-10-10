# Privacy

Tapdeck collects nothing and sends nothing. It has no network code at all: no analytics,
no crash reporting, no update checks. Everything it captures and writes stays on your Mac.

## What stays on your Mac

| What | Where |
|---|---|
| Mixes and settings | Tapdeck's preferences (`~/Library/Preferences/dev.kosuke.Tapdeck.plist`) |
| Audio and screen recordings | `~/Movies/Tapdeck`, or the folder chosen in Settings |
| The list of virtual devices | `/Library/Preferences/Audio/Tapdeck/Devices.plist` |
| The short test recording made by Settings › Diagnostics | `~/Library/Caches/dev.kosuke.Tapdeck/` |
| Driver messages, for troubleshooting | The Mac's own system log, under `dev.kosuke.Tapdeck` |

Audio is processed live in memory. Nothing is recorded to disk unless you start a recording.

## Permissions

| Permission | Why |
|---|---|
| Audio capture | To take the sound of individual apps, or of the whole system, into a mix |
| Microphone | To read input devices: microphones, audio interfaces, and the input side of Tapdeck's own virtual devices |
| Screen recording | Only for screen recordings in the Recording tab |

## What Tapdeck changes on your Mac

- Installing the virtual device driver puts it in `/Library/Audio/Plug-Ins/HAL/`, which
  needs an administrator password once.
- An output's fader sets that device's own volume, as the volume keys do.
- While a mix plays to AirPlay, AirPlay becomes the Mac's output; the previous output comes
  back when the mix stops, or at the next launch if Tapdeck quit unexpectedly.
