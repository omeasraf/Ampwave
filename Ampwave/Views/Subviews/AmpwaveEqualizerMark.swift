//
//  AmpwaveEqualizerMark.swift
//  Ampwave
//
//  Reusable rendition of the nine-bar mark from AppIcon.svg.
//

internal import SwiftUI

struct AmpwaveEqualizerMark: View {
  var isAnimated: Bool
  var showsGlow: Bool = false
  var showsSheen: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var beatIsHigh = false

  private let barHeights: [CGFloat] = [0.40, 0.64, 0.85, 1.00, 0.75, 0.55, 0.80, 0.60, 0.35]
  private let beatDurations: [Double] = [0.48, 0.61, 0.52, 0.68, 0.46, 0.58, 0.50, 0.64, 0.44]

  private var shouldAnimate: Bool { isAnimated && !reduceMotion }

  var body: some View {
    GeometryReader { geometry in
      let gap = max(geometry.size.width * 0.025, 0.5)
      let barWidth = (geometry.size.width - gap * CGFloat(barHeights.count - 1))
        / CGFloat(barHeights.count)

      HStack(alignment: .center, spacing: gap) {
        ForEach(barHeights.indices, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(barGradient)
            .overlay(alignment: .top) {
              if showsSheen {
                Capsule(style: .continuous)
                  .fill(.white.opacity(0.16))
                  .frame(
                    height: min(18, geometry.size.height * barHeights[index] * 0.18)
                  )
              }
            }
            .frame(width: barWidth, height: geometry.size.height * barHeights[index])
            .scaleEffect(
              y: shouldAnimate ? (beatIsHigh ? 1 : 0.24) : 1,
              anchor: .center
            )
            .shadow(
              color: showsGlow
                ? Color(red: 0.91, green: 0.24, blue: 0.54).opacity(0.72)
                : .clear,
              radius: showsGlow ? 14 : 0,
              y: showsGlow ? 2 : 0
            )
            .animation(
              shouldAnimate
                ? .easeInOut(duration: beatDurations[index])
                  .repeatForever(autoreverses: true)
                  .delay(Double(index) * 0.035)
                : nil,
              value: beatIsHigh
            )
        }
      }
      // A repeatForever animation can remain attached after its condition
      // becomes false. Recreate the bars when playback changes so pausing
      // immediately produces the static Ampwave mark.
      .id(shouldAnimate)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { updateAnimationState() }
    .onChange(of: isAnimated) { _, _ in updateAnimationState() }
    .onChange(of: reduceMotion) { _, _ in updateAnimationState() }
  }

  private var barGradient: LinearGradient {
    LinearGradient(
      colors: [
        Color(red: 1.0, green: 0.43, blue: 0.71),
        Color(red: 0.91, green: 0.24, blue: 0.54),
        Color(red: 0.75, green: 0.13, blue: 0.42),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private func updateAnimationState() {
    beatIsHigh = shouldAnimate
  }
}

#Preview("Playing") {
  AmpwaveEqualizerMark(isAnimated: true, showsGlow: true, showsSheen: true)
    .frame(width: 252, height: 160)
    .padding(40)
    .background(Color(red: 0.027, green: 0.008, blue: 0.051))
}

#Preview("Paused row icon") {
  AmpwaveEqualizerMark(isAnimated: false)
    .frame(width: 22, height: 18)
    .padding()
}
