internal import SwiftUI

struct MarqueeText: View {
  let text: String
  let font: Font
  let color: Color

  @State private var offset: CGFloat = 0
  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        if textWidth > geometry.size.width {
          textView
          .offset(x: offset)
        } else {
          textView
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .onAppear {
        containerWidth = geometry.size.width
      }
      .onChange(of: geometry.size.width) { _, width in
        containerWidth = width
      }
    }
    .frame(height: 38)
    .clipped()
    .task(id: animationIdentity) {
      await animateTitle()
    }
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

  private var animationIdentity: String {
    "\(text)|\(Int(textWidth.rounded()))|\(Int(containerWidth.rounded()))|\(reduceMotion)"
  }

  @MainActor
  private func animateTitle() async {
    withAnimation(.none) {
      offset = 0
    }
    let overflow = textWidth - containerWidth
    guard overflow > 1, !reduceMotion else { return }

    let travelDuration = max(2, Double(overflow) / 30)
    do {
      try await Task.sleep(for: .seconds(1.25))
      while !Task.isCancelled {
        withAnimation(.linear(duration: travelDuration)) {
          offset = -overflow
        }
        try await Task.sleep(for: .seconds(travelDuration + 1.25))
        withAnimation(.linear(duration: travelDuration)) {
          offset = 0
        }
        try await Task.sleep(for: .seconds(travelDuration + 1.25))
      }
    } catch {
      // A new title or layout cancels this task. Its replacement always starts
      // from the leading edge, avoiding stale end-of-title offsets.
    }
  }
}
