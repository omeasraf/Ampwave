//
//  UpdateCommunityPromptView.swift
//  Ampwave
//
//  A once-per-release invitation to Ampwave's community and source repository.
//

internal import SwiftUI

enum UpdateCommunityPromptState {
  private static let lastSeenReleaseKey = "com.ampwave.lastSeenCommunityPromptRelease"

  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  static var currentBuild: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
  }

  private static var currentReleaseID: String {
    "\(currentVersion)-\(currentBuild)"
  }

  static var shouldPresent: Bool {
    UserDefaults.standard.string(forKey: lastSeenReleaseKey) != currentReleaseID
  }

  static func markCurrentReleaseSeen() {
    UserDefaults.standard.set(currentReleaseID, forKey: lastSeenReleaseKey)
  }
}

struct UpdateCommunityPromptView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(ThemeManager.self) private var themeManager

  private let discordURL = URL(string: "https://discord.com/invite/gKChVVHRKW")!
  private let githubURL = URL(string: "https://github.com/omeasraf/ampwave")!

  var body: some View {
    ZStack {
      themeManager.backgroundColor
        .ignoresSafeArea()

      Circle()
        .fill(themeManager.accentColor.opacity(0.18))
        .frame(width: 290, height: 290)
        .blur(radius: 46)
        .offset(x: 145, y: -205)
        .allowsHitTesting(false)

      VStack(spacing: 20) {
        header

        VStack(spacing: 8) {
          Text("Thanks for updating Ampwave")
            .font(.title2.bold())
            .foregroundStyle(themeManager.primaryTextColor)
            .multilineTextAlignment(.center)

          Text("Join the community for updates and feedback, or star Ampwave on GitHub to support the project.")
            .font(.subheadline)
            .foregroundStyle(themeManager.secondaryTextColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(spacing: 11) {
          communityButton(
            title: "Join the Discord",
            image: "discord",
            destination: discordURL,
            isProminent: true
          )

          communityButton(
            title: "Star on GitHub",
            image: "github.fill",
            destination: githubURL,
            isProminent: false
          )
        }

        Button("Not now") {
          dismiss()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(themeManager.secondaryTextColor)
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 16)
    }
  }

  private var header: some View {
    HStack(spacing: 15) {
      ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                themeManager.accentColor,
                themeManager.accentColor.lighter(by: 0.18),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )

        AmpwaveEqualizerMark(isAnimated: false, showsGlow: false, showsSheen: true)
          .frame(width: 58, height: 37)
      }
      .frame(width: 74, height: 74)
      .shadow(color: themeManager.accentColor.opacity(0.28), radius: 14, y: 7)

      VStack(alignment: .leading, spacing: 5) {
        Text("AMPWAVE")
          .font(.caption.weight(.bold))
          .tracking(1.8)
          .foregroundStyle(themeManager.accentColor)

        Text("Version \(UpdateCommunityPromptState.currentVersion)")
          .font(.headline)
          .foregroundStyle(themeManager.primaryTextColor)

        Text("Build \(UpdateCommunityPromptState.currentBuild)")
          .font(.caption)
          .foregroundStyle(themeManager.secondaryTextColor)
      }

      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func communityButton(
    title: String,
    image: String,
    destination: URL,
    isProminent: Bool
  ) -> some View {
    Button {
      openURL(destination)
      dismiss()
    } label: {
      HStack(spacing: 10) {
        Image(image)
          .resizable()
          .scaledToFit()
          .frame(width: 19, height: 19)

        Text(title)
          .fontWeight(.semibold)

        Spacer()

        Image(systemName: "arrow.up.right")
          .font(.caption.bold())
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 17)
      .frame(height: 50)
      .foregroundStyle(isProminent ? Color.white : themeManager.primaryTextColor)
      .background {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .fill(isProminent ? themeManager.accentColor : themeManager.cardBackgroundColor)
      }
      .overlay {
        if !isProminent {
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(themeManager.accentColor.opacity(0.28), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  UpdateCommunityPromptView()
    .environment(ThemeManager.shared)
}
