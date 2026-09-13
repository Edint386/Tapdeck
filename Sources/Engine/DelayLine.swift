import Foundation

/// A multichannel delay, used to hold back fast outputs until slow ones —
/// Bluetooth headphones, AirPlay speakers — catch up.
///
/// Audio cannot be sent to a slow device early, so outputs are aligned by
/// delaying every other one instead.
///
/// The delay can change while audio is playing. Moving the read position in
/// one step would put a discontinuity in the waveform, so a change crossfades
/// from the old position to the new one.
final class DelayLine {
    let channelCount: Int
    let capacityFrames: Int
    private let fadeFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0

    private var delay = 0
    private var fadingFrom = 0
    private var fadeRemaining = 0

    /// - Parameters:
    ///   - maximumFrames: the longest delay this line can hold.
    ///   - fadeFrames: length of the crossfade when the delay changes.
    init(channels: Int, maximumFrames: Int, fadeFrames: Int = 2048) {
        channelCount = max(1, channels)
        capacityFrames = max(1, maximumFrames) + 1
        self.fadeFrames = max(1, fadeFrames)
        storage = .allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit { storage.deallocate() }

    /// The delay currently in effect, in frames.
    var currentDelay: Int { delay }

    /// Delay the channels in place by `targetDelay` frames.
    ///
    /// Runs on a real-time thread: no allocation and no locking.
    func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int, targetDelay: Int) {
        let target = min(max(0, targetDelay), capacityFrames - 1)
        if target != delay {
            // Start a new fade from wherever the output is now. If a fade was
            // already under way, its midpoint is close enough as a start.
            fadingFrom = fadeRemaining > 0 ? (fadingFrom + delay) / 2 : delay
            delay = target
            fadeRemaining = fadeFrames
        }

        // Nothing to do while the delay has been zero long enough that no fade
        // is pending — but history is still recorded, so a later change has
        // audio to read.
        let width = min(channels.count, channelCount)

        for frame in 0..<frameCount {
            let slot = writeIndex
            for channel in 0..<width {
                storage[channel * capacityFrames + slot] = channels[channel][frame]
            }

            let readNew = (slot - delay + capacityFrames) % capacityFrames
            if fadeRemaining > 0 {
                let readOld = (slot - fadingFrom + capacityFrames) % capacityFrames
                // Equal-gain linear crossfade: the two positions carry the same
                // programme a moment apart, so they are strongly correlated.
                let t = 1 - Float(fadeRemaining) / Float(fadeFrames)
                for channel in 0..<width {
                    let base = channel * capacityFrames
                    channels[channel][frame] = storage[base + readOld] * (1 - t)
                                             + storage[base + readNew] * t
                }
                fadeRemaining -= 1
            } else if delay > 0 {
                for channel in 0..<width {
                    channels[channel][frame] = storage[channel * capacityFrames + readNew]
                }
            }

            writeIndex = (slot + 1) % capacityFrames
        }
    }
}
