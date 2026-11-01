import SwiftUI

struct SpotifyPulseRing: View {
    let phase: Double
    let maxPhase: Double
    let scale: Double
    let opacity: Double
    let size: CGFloat

    private var progress: Double {
        maxPhase > 0 ? min(phase / maxPhase, 1) : 0
    }

    private var currentScale: CGFloat {
        1 + (scale - 1) * progress
    }

    private var currentOpacity: Double {
        opacity * (1 - progress)
    }

    var body: some View {
        Circle()
            .fill(.white.opacity(currentOpacity * 0.5))
            .frame(width: size, height: size)
            .scaleEffect(currentScale)
    }
}
