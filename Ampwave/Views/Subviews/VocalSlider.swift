//
//  VocalSlider.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/14/26.
//

internal import SwiftUI

struct VocalSlider: View {
  @Binding var value: Float
  @State private var isDragging = false

  // Apple Music Sing uses a range, but typically it doesn't go to zero
  private let minVocal: Float = 0.05

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
              .padding(.bottom, 12)
          }
        }
        .clipShape(Capsule())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { gesture in
              isDragging = true
              let height = geometry.size.height
              let rawValue = 1.0 - Float(gesture.location.y / height)
              value = min(max(rawValue, minVocal), 1.0)
            }
            .onEnded { _ in
              isDragging = false
            }
        )
      }
      .frame(width: 44, height: 200)
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
