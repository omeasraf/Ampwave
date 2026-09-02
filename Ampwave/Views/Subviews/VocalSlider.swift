//
//  VocalSlider.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/14/26.
//

internal import SwiftUI

struct VocalSlider: View {
  @Binding var value: Float
  var vocalActivity: Float? = nil
  @State private var isDragging = false

  private var activityStrength: CGFloat {
    CGFloat(min(max(vocalActivity ?? 0, 0), 1))
  }

  var body: some View {
    VStack(spacing: 12) {
      GeometryReader { geometry in
        ZStack(alignment: .bottom) {
          // Background track
          Capsule()
            .fill(.white.opacity(0.2))

          // Active level
          Capsule()
            .fill(.white)
            .frame(height: max(geometry.size.height * CGFloat(value), 20))
            .shadow(color: .white.opacity(0.5), radius: 10)

          // Icon
          VStack {
            Spacer()
            Image(systemName: "waveform.path")
              .font(.system(size: 20, weight: .bold))
              .foregroundStyle(value > 0.3 ? .black : .white)
              .scaleEffect(1 + activityStrength * 0.12)
              .shadow(
                color: .white.opacity(vocalActivity == nil ? 0 : 0.25 + activityStrength * 0.55),
                radius: 3 + activityStrength * 8
              )
              .animation(.linear(duration: 0.15), value: activityStrength)
              .padding(.bottom, 80)
          }
        }
        .clipShape(Capsule())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { gesture in
              isDragging = true
              let height = geometry.size.height
              let rawValue = 1.0 - Float(gesture.location.y / height)
              value = min(max(rawValue, 0.0), 1.0)
            }
            .onEnded { _ in
              isDragging = false
            }
        )
      }
      .frame(width: 44, height: 200)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Song vocals")
      .accessibilityValue("\(Int((value * 100).rounded())) percent")
      .accessibilityHint(
        vocalActivity.map { "Detected vocal activity \(Int(($0 * 100).rounded())) percent" }
          ?? "Vocal activity analysis unavailable"
      )
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          value = min(1, value + 0.05)
        case .decrement:
          value = max(0, value - 0.05)
        @unknown default:
          break
        }
      }
    }
    .padding(10)
    .background(.ultraThickMaterial)
    .clipShape(Capsule())
    .overlay {
      Capsule()
        .stroke(.white.opacity(0.2), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.5), radius: 30)
  }
}

#Preview {
  ZStack {
    Color.pink.opacity(0.8).ignoresSafeArea()
    VocalSlider(value: .constant(0.6))
  }
}
