//
//  OnboardingView.swift
//  Ampwave
//
//  7-page onboarding: welcome → import → storage → metadata/lyrics → theme → playback → ready.
//  All colors come from ThemeManager so the screen matches the chosen theme.
//

internal import SwiftUI

// MARK: - Main Onboarding View

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @State private var page = 0

  @AppStorage("com.ampwave.onboarding.copyToStorage") private var copyToStorage = true
  @AppStorage("com.ampwave.onboarding.autoFetchMetadata") private var autoFetchMetadata = true
  @AppStorage("com.ampwave.onboarding.autoFetchLyrics") private var autoFetchLyrics = true
  @AppStorage("com.ampwave.onboarding.gaplessPlayback") private var gaplessPlayback = true
  @AppStorage("com.ampwave.onboarding.normalizeVolume") private var normalizeVolume = false
  @AppStorage("com.ampwave.selectedTheme") private var selectedThemeRaw: String = AppTheme.ampwave
    .rawValue

  private let totalPages = 7

  // Derived directly from @AppStorage so SwiftUI re-renders as soon as the
  // user picks a new theme — independent of whether ThemeManager has been
  // initialised yet (first launch) or of the parent's preferredColorScheme.
  private var selectedThemeColorScheme: ColorScheme? {
    switch AppTheme.resolved(fromStoredRaw: selectedThemeRaw) {
    case .light, .catppuccinLatte, .roseGold, .kanagawaLotus, .nordLight, .everforestLight:
      return .light
    case .dark, .oled, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula,
      .nordDark, .everforestDark, .kanagawaWave:
      return .dark
    case .ampwave, .custom:
      return nil
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      // ── Background ────────────────────────────────────────────────────────
      themeManager.backgroundColor.ignoresSafeArea()

      // Subtle accent glow at the very top
      LinearGradient(
        colors: [themeManager.accentColor.opacity(0.25), .clear],
        startPoint: .top,
        endPoint: UnitPoint(x: 0.5, y: 0.45)
      )
      .ignoresSafeArea()

      VStack(spacing: 0) {
        // ── Top bar ───────────────────────────────────────────────────────
        HStack(alignment: .center) {
          HStack(spacing: 6) {
            ForEach(0..<totalPages, id: \.self) { i in
              Capsule()
                .fill(i == page ? themeManager.accentColor : themeManager.accentColor.opacity(0.25))
                .frame(width: i == page ? 22 : 6, height: 6)
                .animation(.spring(duration: 0.3), value: page)
            }
          }
          Spacer()
          if page < totalPages - 1 {
            Button("Skip") { finishOnboarding() }
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 28)
        .padding(.top, 60)
        .padding(.bottom, 4)

        // ── Pages ─────────────────────────────────────────────────────────
        TabView(selection: $page) {
          welcomePage.tag(0)
          importPage.tag(1)
          storagePage.tag(2)
          metadataPage.tag(3)
          themePage.tag(4)
          playbackPage.tag(5)
          readyPage.tag(6)
        }
        #if os(iOS)
          .tabViewStyle(.page(indexDisplayMode: .never))
        #endif

        // ── Continue / Start button ───────────────────────────────────────
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
            .background(themeManager.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 52)
      }
    }
    // Apply color scheme directly from the selected theme so text colors
    // (.primary / .secondary) flip immediately when the user picks a theme,
    // without waiting for ThemeManager to propagate through the presentation boundary.
    .preferredColorScheme(selectedThemeColorScheme)
  }

  // MARK: - Pages

  private var welcomePage: some View {
    OnboardingPageLayout(
      title: "Your music, in motion.",
      subtitle:
        "Ampwave plays your library offline — with synced lyrics, smart recommendations, and a player built around how you actually listen.",
      iconView: {
        AppIconView()
          .frame(width: 100, height: 100)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
      }
    ) {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        ForEach(
          [
            ("music.note.list", "Local & offline"),
            ("waveform", "Hi-res audio"),
            ("text.quote", "Synced lyrics"),
            ("sparkles", "Smart picks"),
          ], id: \.1
        ) { icon, label in
          HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            Text(label).font(.system(size: 14, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(themeManager.accentColor.opacity(0.12))
          .foregroundStyle(themeManager.accentColor)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      }
    }
  }

  private var importPage: some View {
    OnboardingPageLayout(
      icon: "square.and.arrow.down.fill", title: "Import your library",
      subtitle:
        "Add files or entire folders from the Files app. Ampwave indexes in the background so you can start listening immediately."
    ) {
      VStack(alignment: .leading, spacing: 16) {
        OnboardingFlowRow(
          items: ["MP3", "FLAC", "ALAC", "AAC", "AIFF", "WAV", "OGG"],
          accentColor: themeManager.accentColor,
          cardColor: themeManager.cardBackgroundColor)

        VStack(alignment: .leading, spacing: 10) {
          importStep(number: "1", text: "Open **Settings → Import Music**")
          importStep(number: "2", text: "Tap **Add Files** or **Add Folder**")
          importStep(number: "3", text: "Pick your music from Files, iCloud Drive, or any app")
        }
        .padding(16)
        .background(themeManager.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        HStack(spacing: 8) {
          Image(systemName: "arrow.trianglehead.2.clockwise").font(.system(size: 12))
          Text("You can import more any time — your library grows with you.").font(
            .system(size: 13))
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  private func importStep(number: String, text: LocalizedStringKey) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.system(size: 13, weight: .bold))
        .frame(width: 22, height: 22)
        .background(themeManager.accentColor)
        .clipShape(Circle())
        .foregroundStyle(.white)
      Text(text)
        .font(.system(size: 14))
        .foregroundStyle(.primary)
    }
  }

  private var storagePage: some View {
    OnboardingPageLayout(
      icon: "externaldrive.fill", title: "Storage mode",
      subtitle: "Choose how Ampwave handles your audio files."
    ) {
      VStack(spacing: 12) {
        storageCard(
          icon: "folder.fill.badge.plus", title: "Copy to Ampwave",
          description: "Files are copied into the app. Safe from deletion and always available.",
          isSelected: copyToStorage
        ) { copyToStorage = true }

        storageCard(
          icon: "link.circle.fill", title: "Link in Place",
          description:
            "Files stay in their original location. Saves space, but moving them can break the link.",
          isSelected: !copyToStorage
        ) { copyToStorage = false }

        HStack(spacing: 8) {
          Image(systemName: "info.circle").font(.system(size: 12))
          Text("You can change this any time in Settings.").font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var metadataPage: some View {
    OnboardingPageLayout(
      icon: "sparkle.magnifyingglass", title: "Metadata & Lyrics",
      subtitle:
        "Ampwave enriches your library using free, open community databases — no account needed."
    ) {
      VStack(spacing: 12) {
        settingsRow(
          icon: "tag.fill", title: "Auto-fetch metadata",
          description: "Artwork, artist info, and album details via MusicBrainz.",
          isOn: $autoFetchMetadata)
        settingsRow(
          icon: "text.quote", title: "Auto-fetch lyrics",
          description: "Time-synced karaoke lyrics from LRCLIB when available.",
          isOn: $autoFetchLyrics)
        HStack(spacing: 8) {
          Image(systemName: "lock.fill").font(.system(size: 12))
          Text("All requests are anonymous. No account, no tracking, no ads.").font(
            .system(size: 13))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
      }
    }
  }

  private var themePage: some View {
    OnboardingPageLayout(
      icon: "paintpalette.fill", title: "Choose your theme",
      subtitle: "Pick a look that feels like you. You can always change it in Settings."
    ) {
      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10
      ) {
        ForEach(AppTheme.allCases.filter { $0 != .custom }, id: \.self) { theme in
          themeCell(theme)
        }
      }
    }
  }

  private func themeCell(_ theme: AppTheme) -> some View {
    let config = theme.colors(isDark: true)
    let isSelected = AppTheme.resolved(fromStoredRaw: selectedThemeRaw) == theme
    return Button {
      selectedThemeRaw = theme.rawValue
      if let prefs = ThemeManager.shared.userPreferences {
        prefs.selectedTheme = theme
      } else {
        UserDefaults.standard.set(theme.rawValue, forKey: "com.ampwave.selectedTheme")
      }
    } label: {
      VStack(spacing: 6) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(config.background)
            .frame(height: 44)
          HStack(spacing: 4) {
            Circle().fill(config.accent).frame(width: 14, height: 14)
            Circle().fill(config.cardBackground).frame(width: 9, height: 9)
          }
        }
        .overlay(alignment: .topTrailing) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(themeManager.accentColor)
              .font(.system(size: 14, weight: .bold))
              .offset(x: 4, y: -4)
              .shadow(color: .black.opacity(0.2), radius: 2)
          }
        }
        Text(theme.displayName)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(8)
      .background(
        isSelected ? themeManager.accentColor.opacity(0.15) : themeManager.cardBackgroundColor
      )
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? themeManager.accentColor : Color.clear, lineWidth: 1.5)
      }
    }
    .buttonStyle(.plain)
    .animation(.spring(duration: 0.2), value: isSelected)
  }

  private var playbackPage: some View {
    OnboardingPageLayout(
      icon: "hifispeaker.fill", title: "Playback defaults",
      subtitle: "Fine-tune how Ampwave sounds. You can always adjust these in Settings."
    ) {
      VStack(spacing: 12) {
        settingsRow(
          icon: "infinity", title: "Gapless playback",
          description: "Tracks flow into each other without any silence between them.",
          isOn: $gaplessPlayback)
        settingsRow(
          icon: "speaker.wave.3.fill", title: "Volume normalization",
          description: "Keeps loudness consistent across tracks so you're never caught off guard.",
          isOn: $normalizeVolume)
        HStack(spacing: 12) {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 28)
            .foregroundStyle(themeManager.accentColor)
          VStack(alignment: .leading, spacing: 2) {
            Text("Equalizer").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            Text("10-band EQ available in the player controls.")
              .font(.system(size: 13)).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(themeManager.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private var readyPage: some View {
    OnboardingPageLayout(
      icon: "checkmark.circle.fill", title: "You're all set!",
      subtitle:
        "Your preferences are saved. Head to Settings anytime to import music, change themes, or adjust the equalizer."
    ) {
      VStack(spacing: 8) {
        let selectedTheme = AppTheme.resolved(fromStoredRaw: selectedThemeRaw)
        summaryRow(icon: "paintpalette.fill", label: "Theme: \(selectedTheme.displayName)")
        summaryRow(
          icon: copyToStorage ? "folder.fill.badge.plus" : "link.circle.fill",
          label: copyToStorage ? "Files copied to Ampwave" : "Files linked in place")
        summaryRow(
          icon: autoFetchMetadata ? "tag.fill" : "tag.slash.fill",
          label: autoFetchMetadata ? "Metadata auto-fetch on" : "Metadata auto-fetch off")
        summaryRow(
          icon: autoFetchLyrics ? "text.quote" : "text.slash",
          label: autoFetchLyrics ? "Synced lyrics on" : "Lyrics disabled")
        summaryRow(
          icon: gaplessPlayback ? "infinity" : "stop.circle",
          label: gaplessPlayback ? "Gapless playback on" : "Gaps between tracks")
        summaryRow(
          icon: normalizeVolume ? "speaker.wave.3.fill" : "speaker.fill",
          label: normalizeVolume ? "Volume normalization on" : "Volume normalization off")
      }
    }
  }

  // MARK: - Reusable Components

  private func storageCard(
    icon: String, title: String, description: String,
    isSelected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .semibold))
          .frame(width: 32)
          .foregroundStyle(isSelected ? themeManager.accentColor : .secondary)

        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
          Text(description)
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(isSelected ? themeManager.accentColor : .secondary)
      }
      .padding(16)
      .background(
        isSelected ? themeManager.accentColor.opacity(0.1) : themeManager.cardBackgroundColor
      )
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isSelected ? themeManager.accentColor : Color.clear, lineWidth: 1.5)
      }
    }
    .buttonStyle(.plain)
    .animation(.spring(duration: 0.2), value: isSelected)
  }

  private func settingsRow(icon: String, title: String, description: String, isOn: Binding<Bool>)
    -> some View
  {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 30, height: 30)
        .background(themeManager.accentColor.opacity(0.15))
        .foregroundStyle(themeManager.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
        Text(description)
          .font(.system(size: 13)).foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Toggle("", isOn: isOn).labelsHidden().tint(themeManager.accentColor)
    }
    .padding(16)
    .background(themeManager.cardBackgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func summaryRow(icon: String, label: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 26)
        .foregroundStyle(themeManager.accentColor)
      Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(themeManager.cardBackgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Finish

  private func finishOnboarding() {
    // Persist the completion flag.
    UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)

    // If UserPreferences already exists (e.g. re-opening onboarding from Settings),
    // apply all choices directly so Settings reflects them immediately.
    if let prefs = ThemeManager.shared.userPreferences {
      prefs.copyMusicToStorage = copyToStorage
      prefs.autoFetchMetadata = autoFetchMetadata
      prefs.autoFetchLyrics = autoFetchLyrics
      prefs.gaplessPlayback = gaplessPlayback
      prefs.normalizeVolume = normalizeVolume
      prefs.selectedTheme = AppTheme.resolved(fromStoredRaw: selectedThemeRaw)
    }

    dismiss()
  }
}

// MARK: - App Icon View

/// Renders the app's primary icon image so the welcome page shows the real icon.
struct AppIconView: View {
  var body: some View {
    #if os(iOS)
      if let uiImage = UIImage(named: "AppIcon") {
        Image(uiImage: uiImage).resizable().scaledToFit()
      } else {
        Image(systemName: "music.note.house.fill")
          .font(.system(size: 68, weight: .light))
          .symbolRenderingMode(.hierarchical)
      }
    #else
      if let nsImage = NSImage(named: "AppIcon") {
        Image(nsImage: nsImage).resizable().scaledToFit()
      } else {
        Image(systemName: "music.note.house.fill")
          .font(.system(size: 68, weight: .light))
          .symbolRenderingMode(.hierarchical)
      }
    #endif
  }
}

// MARK: - Page Layout Container

struct OnboardingPageLayout<IconContent: View, Extra: View>: View {
  @Environment(ThemeManager.self) private var themeManager
  let title: String
  let subtitle: String
  @ViewBuilder var iconView: () -> IconContent
  @ViewBuilder var extra: () -> Extra

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 26) {
        iconView()
          .padding(.top, 12)

        VStack(spacing: 10) {
          Text(title)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)

          Text(subtitle)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
        }

        extra().padding(.top, 4)
      }
      .padding(.horizontal, 28)
      .padding(.bottom, 24)
    }
  }
}

// MARK: - Convenience init for SF Symbol icon pages

extension OnboardingPageLayout where IconContent == AnyView {
  init(
    icon: String,
    title: String,
    subtitle: String,
    @ViewBuilder extra: @escaping () -> Extra
  ) {
    self.title = title
    self.subtitle = subtitle
    self.extra = extra
    self.iconView = {
      AnyView(
        Image(systemName: icon)
          .font(.system(size: 68, weight: .light))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)  // resolved at runtime via environment
      )
    }
  }
}

// MARK: - Flowing Badge Row

struct OnboardingFlowRow: View {
  let items: [String]
  var accentColor: Color = .accentColor
  var cardColor: Color = .gray.opacity(0.15)
  var spacing: CGFloat = 8

  var body: some View {
    _FlowLayout(spacing: spacing) {
      ForEach(items, id: \.self) { item in
        Text(item)
          .font(.system(size: 13, weight: .bold, design: .monospaced))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(accentColor.opacity(0.12))
          .foregroundStyle(accentColor)
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
  static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: completedKey) }
  static func reset() { UserDefaults.standard.removeObject(forKey: completedKey) }
}
