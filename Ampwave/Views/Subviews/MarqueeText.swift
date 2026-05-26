internal import SwiftUI

struct MarqueeText: View {
  let text: String
  let font: Font
  let color: Color

  @State private var offset: CGFloat = 0
  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @State private var isAnimating = false

  private let spacing: CGFloat = 40

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        if textWidth > geometry.size.width {
          // Animated continuous loop
          HStack(spacing: spacing) {
            textView
            textView
          }
          .offset(x: offset)
          .onAppear {
            containerWidth = geometry.size.width
            startAnimation()
          }
        } else {
          // Static text
          textView
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
              containerWidth = geometry.size.width
              stopAnimation()
            }
        }
      }
      .onAppear {
        containerWidth = geometry.size.width
      }
      .onChange(of: text) { _, _ in
        resetAnimation()
      }
    }
    // Recreate marquee measurement/animation state when the title changes.
    .id(text)
    .frame(height: 38)
    .clipped()
    .mask {
      if textWidth > containerWidth {
        HStack(spacing: 0) {
          Rectangle()
            .fill(
              LinearGradient(
                colors: [.clear, .black],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: offset < -2 ? 12 : 0)

          Rectangle()
            .fill(.black)

          Rectangle()
            .fill(
              LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 12)
        }
      } else {
        Rectangle().fill(.black)
      }
    }
  }

  private var textView: some View {
    Text(text)
      .font(font)
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .background(
        GeometryReader { textGeometry in
          Color.clear
            .onAppear {
              textWidth = textGeometry.size.width
            }
            .onChange(of: text) { _, _ in
              textWidth = textGeometry.size.width
            }
        }
      )
  }

  private func stopAnimation() {
    isAnimating = false
    offset = 0
  }

  private func resetAnimation() {
    isAnimating = false
    withAnimation(.none) {
      offset = 0
    }
    // Brief delay to allow textWidth to update and state to settle
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if textWidth > containerWidth {
        startAnimation()
      }
    }
  }

  private func startAnimation() {
    guard textWidth > containerWidth, !isAnimating else { return }
    isAnimating = true

    let duration = Double(textWidth + spacing) / 30.0

    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
      offset = -(textWidth + spacing)
    }
  }
}
