# Tapdeck for Windows

Work in progress on the `feature/windows` branch, following the plan in
[`docs/windows-port.md`](../docs/windows-port.md). Nothing here runs on Windows as an app
yet.

## What is here

| Path | What it is |
|---|---|
| `engine/` | The engine's portable C++20 code: the gain stages (`GainRamp`, `MasterVolume`, `LookaheadLimiter`), the routing graph, and the lock-free ring buffer. No Windows dependency, so it also builds on the Mac. |
| `tests/` | Offline tests: `graphtest`, `gaintest` and `limittest` port tapproof's tests of the same names; `ringtest` covers the ring buffer; `vectortest` checks the C++ code against the reference vectors. |
| `vectors/` | Reference vectors: inputs and the outputs the macOS engine's own Swift code produces for them. |
| `tools/vectors/` | The generator that writes them, compiled together with the unchanged `Sources/Engine` files. |
| `PARITY.md` | Each Swift file, its C++ counterpart, the macOS commit last followed, and what differs. |

## Building and testing

On the Mac, with the same toolchain choice as `build.sh`:

```
windows/tools/build-mac.sh            # build, then run every test
windows/tools/build-mac.sh thread     # ringtest under ThreadSanitizer
windows/tools/build-mac.sh address    # every test under AddressSanitizer
```

On Windows, with Visual Studio's C++ tools and CMake:

```
cmake -S windows -B build -A x64
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

GitHub Actions does both (`.github/workflows/windows-engine.yml`).

## Reference vectors

```
windows/tools/vectors.sh check      # do the vectors still match the Swift code?
windows/tools/vectors.sh write      # regenerate them
windows/tools/vectors.sh selftest   # show that check catches a stale vector
```

The generator is built from the unchanged `GainStage.swift` and `RoutingGraph.swift`, so the
vectors are, by definition, what the macOS engine computes. When a merge from the macOS code
changes those files, `check` fails in CI; regenerate with `write` and bring the C++ code in
line until `vectortest` passes.

The files are `.tdv`: named arrays of 32- and 64-bit floats, 32-bit integers and text,
little-endian (format in `tests/VectorFile.h`). Floating point is kept strict on both
compilers — no fused multiply-add, no fast-math — so the gain ramp, master volume and
limiter match the Swift output bit for bit on the Mac. Across Apple's and Microsoft's math
libraries the limiter may differ by the last bit of an `exp()`; `vectortest` allows 1e-6
(−120 dBFS) there and nothing elsewhere.
