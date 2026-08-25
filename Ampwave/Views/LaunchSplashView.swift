//
//  LaunchSplashView.swift
//  Ampwave
//
//  Animated launch mark based on the equalizer in AppIcon.svg.
//

internal import SwiftUI

struct LaunchSplashView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var barsArePlaying = false
  @State private var contentIsVisible = false

  var body: some View {
    ZStack {
      RadialGradient(
        colors: [Color(red: 0.125, green: 0.043, blue: 0.251),
          Color(red: 0.027, green: 0.008, blue: 0.051)],
        center: UnitPoint(x: 0.5, y: 0.42),
        startRadius: 0,
        endRadius: 520
      )
      .ignoresSafeArea()

      AmpwaveEqualizerMark(
        isAnimated: barsArePlaying,
        showsGlow: true,
        showsSheen: true
      )
        .frame(width: 252, height: 160)
        .scaleEffect(contentIsVisible ? 1 : 0.82)
        .opacity(contentIsVisible ? 1 : 0)

      Text("YOUR MUSIC, IN MOTION")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .tracking(2.7)
        .foregroundStyle(.white.opacity(0.58))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 42)
        .offset(y: contentIsVisible ? 0 : 10)
        .opacity(contentIsVisible ? 1 : 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Ampwave")
    .onAppear {
      if reduceMotion {
        barsArePlaying = true
        contentIsVisible = true
        return
      }

      withAnimation(.spring(response: 0.62, dampingFraction: 0.72)) {
        contentIsVisible = true
      }
      barsArePlaying = true
    }
  }

}

#Preview {
  LaunchSplashView()
}
