//
//  OnboardingView.swift
//  Ampwave
//

internal import SwiftUI

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @State private var page = 0

  private let pages = [
    (
      "Welcome to Ampwave",
      "Play your library offline, with lyrics, recommendations, and a home built around your music.",
      "music.note.house"
    ),
    (
      "Import your tracks",
      "Add files or folders from the Files app. Ampwave indexes in the background.",
      "square.and.arrow.down"
    ),

  ]

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $page) {
        ForEach(0..<pages.count, id: \.self) { i in
          VStack(spacing: 24) {
            Image(systemName: pages[i].2)
              .font(.system(size: 64))
              .foregroundStyle(themeManager.accentColor)
              .accessibilityHidden(true)
            Text(pages[i].0)
              .font(.title.bold())
              .multilineTextAlignment(.center)
            Text(pages[i].1)
              .font(.body)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 8)
          }
          .tag(i)
          .padding(24)
        }
      }
      #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .always))
      #endif

      Button {
        if page < pages.count - 1 {
          page += 1
        } else {
          UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
          dismiss()
        }
      } label: {
        Text(page < pages.count - 1 ? "Next" : "Get Started")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
          .background(themeManager.accentColor)
          .foregroundStyle(.white)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      .padding(24)
    }
    .background(themeManager.backgroundColor)
  }
}

enum OnboardingState {
  static let completedKey = "Ampwave.onboarding.completed.v1"
  static var shouldShow: Bool {
    !UserDefaults.standard.bool(forKey: completedKey)
  }
}
