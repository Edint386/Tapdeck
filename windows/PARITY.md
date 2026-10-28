# Parity with the macOS engine

Each Swift file the Windows engine follows, its C++ counterpart, the macOS commit last
followed, and the deliberate divergences. When a merge brings a newer commit for one of
these files, update the C++ code, regenerate the reference vectors where they apply, and
move the commit here.

| Swift | C++ | Last followed | Checked by |
|---|---|---|---|
| `Sources/Engine/GainStage.swift` — `MasterVolume`, `GainRamp`, `LookaheadLimiter` | `engine/…/GainStage.h`, `engine/src/GainStage.cpp` | `7bed099` (2026-09-18) | `vectortest`, `gaintest`, `limittest` |
| `Sources/Engine/RoutingGraph.swift` | `engine/…/RoutingGraph.h`, `engine/src/RoutingGraph.cpp` | `2cc63ec` (2026-09-13) | `vectortest`, `graphtest` |
| `Sources/Engine/AudioRingBuffer.swift` (design only) | `engine/…/AudioRingBuffer.h`, `engine/src/AudioRingBuffer.cpp` | `42e9002` (2026-09-13) | `ringtest` |

Not yet ported: `PeakLimiter` and `clipAndMeasure` in `GainStage.swift`, which arrive with
the rest of the DSP in milestone M4.

## Deliberate divergences

### `MasterVolume`

- Volume and mute share one 64-bit atomic instead of sitting behind an `os_unfair_lock`, so
  a real-time reader never waits and always sees a matching pair. Behaviour is the same,
  including negative volumes stored as 0.

### `AudioRingBuffer`

The macOS buffer takes an `NSLock` from both the source's thread and the output's. The
Windows buffer takes none, which changes four things:

- **Overflow is found by the reader.** The writer never looks at the reader; when the reader
  finds more than three quarters of the buffer unread, it drops the oldest frames, keeps the
  newest half, and counts one overrun. macOS waits until the buffer is completely full and
  keeps all of it, which is safe there only because the lock keeps the writer out while it
  reads. Keeping a quarter of the buffer between the two means a read would have to take
  longer than the writer needs for a quarter of the buffer (about 85 ms at the default size)
  before they touched the same frames. Should that still happen, the read is counted as an
  overrun too; the writer announces each block before storing it so that the reader can tell.
  Overrun counts therefore differ from macOS: one per read that finds an overflow, not one
  per write that causes it.
- **Two write methods.** macOS has two `write` overloads that treat missing channels
  differently: a buffer from a source fans a mono source out and repeats its last channel,
  while planar writes leave missing channels silent. They are `writeMapped` and `write`.
- **`setPrimeFrames` reaches the reader through a flag**, applied at its next read. macOS
  resets priming immediately under its lock; both take effect at the next priming.
- **`clear` may only be called while neither side runs.** macOS clears under its lock.

The samples are stored as relaxed atomics, which on x64 and arm64 are plain loads and stores,
so that an overflowing writer and the reader may touch the same frame without undefined
behaviour.

### `RoutingGraph`

- Devices are ordered as UTF-8 bytes. Swift orders strings by Unicode scalar values after
  normalisation, which is the same order for normalised text such as endpoint IDs and the
  names in `vectortest`.
