//
//  OnboardingView.swift
//  Ampwave
//
//  Rich 6-page onboarding: welcome → import guide → storage → metadata/lyrics → playback → ready.
//  Interactive toggles write to UserDefaults so UserPreferences.init() picks them up on first run.
//

internal import SwiftUI

// MARK: - Main Onboarding View

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @State private var page = 0

  // Choices persisted so UserPreferences.init() can read them on first launch.
  @AppStorage("com.ampwave.onboarding.copyToStorage") private var copyToStorage = true
  @AppStorage("com.ampwave.onboarding.autoFetchMetadata") private var autoFetchMetadata = true
  @AppStorage("com.ampwave.onboarding.autoFetchLyrics") private var autoFetchLyrics = true
  @AppStorage("com.ampwave.onboarding.gaplessPlayback") private var gaplessPlayback = true
  @AppStorage("com.ampwave.onboarding.normalizeVolume") private var normalizeVolume = false

  private let totalPages = 6

  var body: some View {
    ZStack(alignment: .top) {
      // Animated gradient background — shifts with each page
      pageGradient
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: page)

      VStack(spacing: 0) {
        // ── Top bar ─────────────────────────────────────────────────────────
        HStack(alignment: .center) {
          // Animated progress dots
          HStack(spacing: 6) {
            ForEach(0..<totalPages, id: \.self) { i in
              Capsule()
                .fill(i == page ? Color.white : Color.white.opacity(0.3))
                .frame(width: i == page ? 22 : 6, height: 6)
                .animation(.spring(duration: 0.3), value: page)
            }
          }

          Spacer()

          if page < totalPages - 1 {
            Button("Skip") { finishOnboarding() }
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(.white.opacity(0.75))
          }
        }
        .padding(.horizontal, 28)
        .padding(.top, 60)
        .padding(.bottom, 4)

        // ── Page content ────────────────────────────────────────────────────
        TabView(selection: $page) {
          welcomePage.tag(0)
          importPage.tag(1)
          storagePage.tag(2)
          metadataPage.tag(3)
          playbackPage.tag(4)
          readyPage.tag(5)
        }
        #if os(iOS)
          .tabViewStyle(.page(indexDisplayMode: .never))
        #endif

        // ── Continue / Start button ──────────────────────────────────────────
        Button {
          if page < totalPages - 1 {
            withAnimation(.spring(duration: 0.35)) { page += 1 }
          } else {
            finishOnboarding()
          }
        } label: {
          Text(page < totalPages - 1 ? "Continue" : "Start Listening")
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Color.white)
            .foregroundStyle(pageGradientColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 52)
      }
    }
  }

  // MARK: - Pages

  private var welcomePage: some View {
    OnboardingPageLayout(
      icon: "music.note.house.fill",
      title: "Your music, unlocked.",
      subtitle: "Ampwave plays your library offline — with synced lyrics, smart recommendations, and a player built around how you actually listen."
    ) {
      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible())],
        spacing: 10
      ) {
        ForEach(
          [
            ("music.note.list", "Local & offline"),
            ("waveform", "Hi-res audio"),
            ("text.quote", "Synced lyrics"),
            ("sparkles", "Smart picks"),
          ],
          id: \.1
        ) { icon, label in
          HStack(spacing: 8) {
            Image(systemName: icon)
              .font(.system(size: 14, weight: .semibold))
            Text(label)
              .font(.system(size: 14, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Color.white.opacity(0.15))
          .foregroundStyle(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      }
    }
  }

  private var importPage: some View {
    OnboardingPageLayout(
      icon: "square.and.arrow.down.fill",
      title: "Import your library",
      subtitle: "Add files or entire folders from the Files app. Ampwave indexes in the background so you can start listening immediately."
    ) {
      VStack(alignment: .leading, spacing: 16) {
        // Format badges
        OnboardingFlowRow(items: ["MP3", "FLAC", "ALAC", "AAC", "AIFF", "WAV", "OGG"])

        // Steps
        VStack(alignment: .leading, spacing: 10) {
          importStep(number: "1", text: "Open **Settings → Import Music**")
          importStep(number: "2", text: "Tap **Add Files** or **Add Folder**")
          importStep(number: "3", text: "Pick your music from Files, iCloud Drive, or any app")
        }
        .padding(16)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        HStack(spacing: 8) {
          Image(systemName: "arrow.trianglehead.2.clockwise")
            .font(.system(size: 12))
          Text("You can import more any time — your library grows with you.")
            .font(.system(size: 13))
        }
        .foregroundStyle(Color.white.opacity(0.65))
      }
    }
  }

  private func importStep(number: String, text: LocalizedStringKey) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.system(size: 13, weight: .bold))
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.25))
        .clipShape(Circle())
        .foregroundStyle(Color.white)
      Text(text)
        .font(.system(size: 14))
        .foregroundStyle(Color.white.opacity(0.9))
    }
  }

  private var storagePage: some View {
    OnboardingPageLayout(
      icon: "externaldrive.fill",
      title: "Storage mode",
      subtitle: "Choose how Ampwave handles your audio files."
    ) {
      VStack(spacing: 12) {
        storageCard(
          icon: "folder.fill.badge.plus",
          title: "Copy to Ampwave",
          description: "Files are copied into the app. Safe from deletion and always available.",
          isSelected: copyToStorage
        ) { copyToStorage = true }

        storageCard(
          icon: "link.circle.fill",
          title: "Link in Place",
          description: "Files stay in their original location. Saves space, but moving them can break the link.",
          isSelected: !copyToStorage
        ) { copyToStorage = false }

        HStack(spacing: 8) {
          Image(systemName: "info.circle")
            .font(.system(size: 12))
          Text("You can change this any time in Settings.")
            .font(.system(size: 13))
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var metadataPage: some View {
    OnboardingPageLayout(
      icon: "sparkle.magnifyingglass",
      title: "Metadata & Lyrics",
      subtitle: "Ampwave enriches your library using free, open community databases — no account needed."
    ) {
      VStack(spacing: 12) {
        settingsRow(
          icon: "tag.fill",
          title: "Auto-fetch metadata",
          description: "Artwork, artist info, and album details via MusicBrainz.",
          isOn: $autoFetchMetadata
        )
        settingsRow(
          icon: "text.quote",
          title: "Auto-fetch lyrics",
          description: "Time-synced karaoke lyrics from LRCLIB when available.",
          isOn: $autoFetchLyrics
        )

        HStack(spacing: 8) {
          Image(systemName: "lock.fill")
            .font(.system(size: 12))
          Text("All requests are anonymous. No account, no tracking, no ads.")
            .font(.system(size: 13))
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
      }
    }
  }

  private var playbackPage: some View {
    OnboardingPageLayout(
      icon: "hifispeaker.fill",
      title: "Playback defaults",
      subtitle: "Fine-tune how Ampwave sounds. You can always adjust these in Settings."
    ) {
      VStack(spacing: 12) {
        settingsRow(
          icon: "infinity",
          title: "Gapless playback",
          description: "Tracks flow into each other without any silence between them.",
          isOn: $gaplessPlayback
        )
        settingsRow(
          icon: "speaker.wave.3.fill",
          title: "Volume normalization",
          description: "Keeps loudness consistent across tracks so you're never caught off guard.",
          isOn: $normalizeVolume
        )

        // Teaser for equalizer
        HStack(spacing: 12) {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 28)
            .foregroundStyle(Color.white.opacity(0.7))
          VStack(alignment: .leading, spacing: 2) {
            Text("Equalizer")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color.white)
            Text("10-band EQ available in the player controls.")
              .font(.system(size: 13))
              .foregroundStyle(Color.white.opacity(0.6))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private var readyPage: some View {
    OnboardingPageLayout(
      icon: "checkmark.circle.fill",
      title: "You're all set!",
      subtitle: "Your preferences are saved. Head to Settings anytime to import music, change themes, or adjust the equalizer."
    ) {
      VStack(spacing: 8) {
        summaryRow(
          icon: copyToStorage ? "folder.fill.badge.plus" : "link.circle.fill",
          label: copyToStorage ? "Files copied to Ampwave" : "Files linked in place"
        )
        summaryRow(
          icon: autoFetchMetadata ? "tag.fill" : "tag.slash.fill",
          label: autoFetchMetadata ? "Metadata auto-fetch on" : "Metadata auto-fetch off"
        )
        summaryRow(
          icon: autoFetchLyrics ? "text.quote" : "text.slash",
          label: autoFetchLyrics ? "Synced lyrics on" : "Lyrics disabled"
        )
        summaryRow(
          icon: gaplessPlayback ? "infinity" : "stop.circle",
          label: gaplessPlayback ? "Gapless playback on" : "Gaps between tracks"
        )
        summaryRow(
          icon: normalizeVolume ? "speaker.wave.3.fill" : "speaker.fill",
          label: normalizeVolume ? "Volume normalization on" : "Volume normalization off"
        )
      }
    }
  }

  // MARK: - Reusable Components

  private func storageCard(
    icon: String,
    title: String,
    description: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .semibold))
          .frame(width: 32)
          .foregroundStyle(Color.white)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
          Text(description)
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.75))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.4))
      }
      .padding(16)
      .background(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isSelected ? Color.white.opacity(0.5) : Color.clear, lineWidth: 1.5)
      }
    }
    .buttonStyle(.plain)
    .animation(.spring(duration: 0.2), value: isSelected)
  }

  private func settingsRow(
    icon: String,
    title: String,
    description: String,
    isOn: Binding<Bool>
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 30, height: 30)
        .background(Color.white.opacity(0.2))
        .foregroundStyle(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.white)
        Text(description)
          .font(.system(size: 13))
          .foregroundStyle(Color.white.opacity(0.7))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Toggle("", isOn: isOn)
        .labelsHidden()
        .tint(Color.white.opacity(0.9))
    }
    .padding(16)
    .background(Color.white.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func summaryRow(icon: String, label: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 26)
        .foregroundStyle(Color.white)
      Text(label)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color.white)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(Color.white.opacity(0.13))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Gradient

  private var pageGradientColor: Color {
    switch page {
    case 0: return Color(red: 0.3, green: 0.1, blue: 0.8)   // deep indigo
    case 1: return Color(red: 0.1, green: 0.35, blue: 0.85)  // blue
    case 2: return Color(red: 0.05, green: 0.55, blue: 0.65) // teal
    case 3: return Color(red: 0.55, green: 0.15, blue: 0.75) // purple
    case 4: return Color(red: 0.85, green: 0.4, blue: 0.1)   // orange
    default: return Color(red: 0.1, green: 0.6, blue: 0.35)  // green
    }
  }

  @ViewBuilder
  private var pageGradient: some View {
    LinearGradient(
      colors: [
        pageGradientColor,
        pageGradientColor.opacity(0.55),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    // Subtle noise texture via a second gradient
    .overlay {
      LinearGradient(
        colors: [Color.black.opacity(0.1), Color.black.opacity(0.35)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  // MARK: - Finish

  private func finishOnboarding() {
    UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
    dismiss()
  }
}

// MARK: - Page Layout Container

struct OnboardingPageLayout<Extra: View>: View {
  let icon: String
  let title: String
  let subtitle: String
  @ViewBuilder var extra: () -> Extra

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 26) {
        // Hero icon
        Image(systemName: icon)
          .font(.system(size: 68, weight: .light))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.white)
          .padding(.top, 12)

        // Heading + subtitle
        VStack(spacing: 10) {
          Text(title)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)

          Text(subtitle)
            .font(.system(size: 16))
            .foregroundStyle(Color.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
        }

        // Page-specific content
        extra()
          .padding(.top, 4)
      }
      .padding(.horizontal, 28)
      .padding(.bottom, 24)
    }
  }
}

// MARK: - Flowing Badge Row (for format labels)

struct OnboardingFlowRow: View {
  let items: [String]
  var spacing: CGFloat = 8

  var body: some View {
    _FlowLayout(spacing: spacing) {
      ForEach(items, id: \.self) { item in
        Text(item)
          .font(.system(size: 13, weight: .bold, design: .monospaced))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.white.opacity(0.2))
          .foregroundStyle(Color.white)
          .clipShape(Capsule())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Custom Flow Layout

struct _FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = layout(proposal: proposal, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size)
      )
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (
    size: CGSize, frames: [CGRect]
  ) {
    let maxW = proposal.width ?? 300
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowH: CGFloat = 0

    for subview in subviews {
      let sz = subview.sizeThatFits(.unspecified)
      if x + sz.width > maxW, x > 0 {
        x = 0
        y += rowH + spacing
        rowH = 0
      }
      frames.append(CGRect(x: x, y: y, width: sz.width, height: sz.height))
      x += sz.width + spacing
      rowH = max(rowH, sz.height)
    }
    return (CGSize(width: maxW, height: y + rowH), frames)
  }
}

// MARK: - Onboarding State

enum OnboardingState {
  static let completedKey = "Ampwave.onboarding.completed.v1"
  static var shouldShow: Bool {
    !UserDefaults.standard.bool(forKey: completedKey)
  }

  /// Call after resetting the app or during development to show onboarding again.
  static func reset() {
    UserDefaults.standard.removeObject(forKey: completedKey)
  }
}
