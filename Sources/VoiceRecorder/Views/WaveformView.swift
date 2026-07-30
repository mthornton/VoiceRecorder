import SwiftUI

/// Live input-level meter shown while recording.
///
/// This is a level history, not a rendering of the waveform in the file — it
/// exists so the user can see at a glance that the mic is actually picking them
/// up, which is the failure that otherwise isn't discovered until playback.
struct WaveformView: View {
    let levels: [Float]
    var barCount = 60

    var body: some View {
        GeometryReader { geometry in
            let padded = paddedLevels
            let spacing: CGFloat = 3
            let width = max((geometry.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount), 1)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.tint)
                        .frame(
                            width: width,
                            height: max(CGFloat(level) * geometry.size.height, 3)
                        )
                        .opacity(level > 0 ? 1 : 0.25)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.05), value: levels.count)
        }
    }

    /// Right-aligns the history so new bars enter from the right and the meter
    /// doesn't jump around while the buffer is still filling.
    private var paddedLevels: [Float] {
        if levels.count >= barCount {
            return Array(levels.suffix(barCount))
        }
        return Array(repeating: 0, count: barCount - levels.count) + levels
    }
}
