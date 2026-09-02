//
//  UserPreferences.swift
//  Ampwave
//
//  User preferences and app settings.
//

import Foundation
import SwiftData
internal import SwiftUI

#if os(macOS)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

// MARK: - Theme Models

struct ThemeConfig {
  let background: Color
  let cardBackground: Color
  let accent: Color
  let primaryText: Color
  let secondaryText: Color
  let isDark: Bool
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
  case ampwave
  case light
  case dark
  case oled
  case roseGold
  case catppuccinLatte
  case catppuccinFrappe
  case catppuccinMacchiato
  case catppuccinMocha
  case dracula
  case nordDark
  case nordLight
  case everforestDark
  case everforestLight
  case kanagawaWave
  case kanagawaLotus
  case custom

  var id: String { rawValue }

  /// Maps removed theme raw values and unknown keys to a sensible default.
  static func resolved(fromStoredRaw raw: String?) -> AppTheme {
    guard let raw, !raw.isEmpty else { return .ampwave }
    if raw == "midnightBlue" { return .dark }
    return AppTheme(rawValue: raw) ?? .ampwave
  }

  var displayName: String {
    switch self {
    case .ampwave: return "Ampwave"
    case .light: return "Light"
    case .dark: return "Dark"
    case .oled: return "OLED"
    case .roseGold: return "Rose Gold"
    case .catppuccinLatte: return "Catppuccin Latte"
    case .catppuccinFrappe: return "Catppuccin Frappé"
    case .catppuccinMacchiato: return "Catppuccin Macchiato"
    case .catppuccinMocha: return "Catppuccin Mocha"
    case .dracula: return "Dracula"
    case .nordDark: return "Nord Dark"
    case .nordLight: return "Nord Light"
    case .everforestDark: return "Everforest Dark"
    case .everforestLight: return "Everforest Light"
    case .kanagawaWave: return "Kanagawa Wave"
    case .kanagawaLotus: return "Kanagawa Lotus"
    case .custom: return "Custom"
    }
  }

  func colors(
    isDark: Bool, customBackground: Color? = nil, customAccent: Color? = nil,
    customCard: Color? = nil, customPrimaryText: Color? = nil,
    customSecondaryText: Color? = nil
  ) -> ThemeConfig {
    let actualIsDark: Bool
    switch self {
    case .ampwave: actualIsDark = isDark
    case .light, .catppuccinLatte, .roseGold, .kanagawaLotus, .nordLight, .everforestLight:
      actualIsDark = false
    case .dark, .oled, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula,
      .nordDark, .everforestDark, .kanagawaWave:
      actualIsDark = true
    case .custom: actualIsDark = isDark
    }

    let bg: Color
    let accent: Color
    let card: Color?

    switch self {
    case .ampwave:
      // The default theme remains adaptive, but now carries Ampwave's own
      // lively pearl/aubergine palette instead of falling back to system gray.
      bg = actualIsDark ? Color(hex: "#100916") : Color(hex: "#FFF6FC")
      accent = actualIsDark ? Color(hex: "#FF4FA3") : Color(hex: "#F20F7A")
      card = actualIsDark ? Color(hex: "#281532") : Color(hex: "#FFFFFF")
    case .light:
      // Bright pearl surfaces with a saturated Ampwave pink. The slight plum
      // cast keeps the theme lively without tinting artwork or hurting contrast.
      bg = Color(hex: "#FFF6FC")
      accent = Color(hex: "#F20F7A")
      card = Color(hex: "#FFFFFF")
    case .dark:
      // Deep aubergine instead of flat charcoal gives glass, cards, and the
      // signature pink enough chroma to feel distinctly Ampwave.
      bg = Color(hex: "#100916")
      accent = Color(hex: "#FF4FA3")
      card = Color(hex: "#281532")
    case .oled:
      bg = .black
      accent = Color(red: 232 / 255.0, green: 61 / 255.0, blue: 137 / 255.0)  // #E83D89
      card = Color(red: 22 / 255.0, green: 22 / 255.0, blue: 24 / 255.0)
    case .roseGold:
      bg = Color(red: 0.98, green: 0.92, blue: 0.94)
      accent = Color(red: 190 / 255.0, green: 120 / 255.0, blue: 135 / 255.0)
      card = Color(red: 1.0, green: 0.96, blue: 0.97)
    // Catppuccin: https://github.com/catppuccin/palette — Base, Surface0, Mauve, Text, Subtext1
    case .catppuccinLatte:
      bg = Color(red: 239 / 255.0, green: 241 / 255.0, blue: 245 / 255.0)
      accent = Color(red: 136 / 255.0, green: 57 / 255.0, blue: 239 / 255.0)
      card = Color(red: 204 / 255.0, green: 208 / 255.0, blue: 218 / 255.0)
    case .catppuccinFrappe:
      bg = Color(red: 48 / 255.0, green: 52 / 255.0, blue: 70 / 255.0)
      accent = Color(red: 202 / 255.0, green: 158 / 255.0, blue: 230 / 255.0)
      card = Color(red: 65 / 255.0, green: 69 / 255.0, blue: 89 / 255.0)
    case .catppuccinMacchiato:
      bg = Color(red: 36 / 255.0, green: 39 / 255.0, blue: 58 / 255.0)
      accent = Color(red: 198 / 255.0, green: 160 / 255.0, blue: 246 / 255.0)
      card = Color(red: 54 / 255.0, green: 58 / 255.0, blue: 79 / 255.0)
    case .catppuccinMocha:
      bg = Color(red: 30 / 255.0, green: 30 / 255.0, blue: 46 / 255.0)
      accent = Color(red: 203 / 255.0, green: 166 / 255.0, blue: 247 / 255.0)
      card = Color(red: 49 / 255.0, green: 50 / 255.0, blue: 68 / 255.0)
    case .dracula:
      bg = Color(red: 40 / 255.0, green: 42 / 255.0, blue: 54 / 255.0)
      accent = Color(red: 189 / 255.0, green: 147 / 255.0, blue: 249 / 255.0)
      card = Color(red: 68 / 255.0, green: 71 / 255.0, blue: 90 / 255.0)
    case .nordDark:
      bg = Color(hex: "#2E3440")
      accent = Color(hex: "#88C0D0")
      card = Color(hex: "#3B4252")
    case .nordLight:
      bg = Color(hex: "#ECEFF4")
      accent = Color(hex: "#5E81AC")
      card = Color(hex: "#E5E9F0")
    case .everforestDark:
      bg = Color(hex: "#2D353B")
      accent = Color(hex: "#A7C080")
      card = Color(hex: "#323C41")
    case .everforestLight:
      bg = Color(hex: "#F3EFDA")
      accent = Color(hex: "#8DA101")
      card = Color(hex: "#FDF6E3")
    case .kanagawaWave:
      bg = Color(hex: "#1F1F28")
      accent = Color(hex: "#7E9CD8")
      card = Color(hex: "#2A2A37")
    case .kanagawaLotus:
      bg = Color(hex: "#F2ECBC")
      accent = Color(hex: "#C84053")
      card = Color(hex: "#E4E0BE")
    case .custom:
      bg = customBackground ?? (actualIsDark ? .black : .white)
      accent = customAccent ?? Color.pink
      card = customCard ?? (actualIsDark ? Color(white: 0.1) : Color(white: 0.9))
    }

    let actualCard = card ?? (actualIsDark ? bg.lighter(by: 0.05) : bg.darker(by: 0.05))
    let primaryText: Color
    let secondaryText: Color
    switch self {
    case .ampwave:
      primaryText = Color.primary
      secondaryText = Color.secondary
    case .light:
      primaryText = Color(hex: "#281321")
      secondaryText = Color(hex: "#765568")
    case .dark:
      primaryText = Color(hex: "#FFF4FA")
      secondaryText = Color(hex: "#D6B8CB")
    case .custom:
      primaryText = customPrimaryText ?? (actualIsDark ? Color.white : Color(hex: "#20151C"))
      secondaryText = customSecondaryText
        ?? (actualIsDark ? Color.white.opacity(0.72) : Color(hex: "#6E5D67"))
    case .catppuccinLatte:
      primaryText = Color(red: 76 / 255.0, green: 79 / 255.0, blue: 105 / 255.0)
      secondaryText = Color(red: 92 / 255.0, green: 95 / 255.0, blue: 119 / 255.0)
    case .catppuccinFrappe:
      primaryText = Color(red: 198 / 255.0, green: 208 / 255.0, blue: 245 / 255.0)
      secondaryText = Color(red: 181 / 255.0, green: 191 / 255.0, blue: 226 / 255.0)
    case .catppuccinMacchiato:
      primaryText = Color(red: 202 / 255.0, green: 211 / 255.0, blue: 245 / 255.0)
      secondaryText = Color(red: 184 / 255.0, green: 192 / 255.0, blue: 224 / 255.0)
    case .catppuccinMocha:
      primaryText = Color(red: 205 / 255.0, green: 214 / 255.0, blue: 244 / 255.0)
      secondaryText = Color(red: 186 / 255.0, green: 194 / 255.0, blue: 222 / 255.0)
    case .nordLight:
      primaryText = Color(hex: "#2E3440")
      secondaryText = Color(hex: "#4C566A")
    case .everforestLight:
      primaryText = Color(hex: "#5C6A72")
      secondaryText = Color(hex: "#829181")
    case .kanagawaLotus:
      primaryText = Color(hex: "#54546D")
      secondaryText = Color(hex: "#7E8D85")
    case .roseGold:
      primaryText = Color(red: 0.25, green: 0.15, blue: 0.18)
      secondaryText = Color(red: 0.45, green: 0.35, blue: 0.38)
    default:
      primaryText = actualIsDark ? Color.white : Color.black
      secondaryText = actualIsDark ? Color.white.opacity(0.72) : Color.black.opacity(0.62)
    }

    return ThemeConfig(
      background: bg,
      cardBackground: actualCard,
      accent: accent,
      primaryText: primaryText,
      secondaryText: secondaryText,
      isDark: actualIsDark
    )
  }
}

@Observable
final class ThemeManager {
  static let shared = ThemeManager()

  var userPreferences: UserPreferences?
  @ObservationIgnored var ampwaveColorScheme: ColorScheme = .dark

  var currentTheme: AppTheme {
    if let prefs = userPreferences { return prefs.selectedTheme }
    let raw = UserDefaults.standard.string(forKey: "com.ampwave.selectedTheme")
    return AppTheme.resolved(fromStoredRaw: raw)
  }

  var themeConfig: ThemeConfig {
    currentTheme.colors(
      isDark: ampwaveColorScheme == .dark,
      customBackground: (userPreferences?.customBackgroundColorHex
        ?? UserDefaults.standard.string(forKey: "com.ampwave.customBackground")).map {
          Color(hex: $0)
        },
      customAccent: (userPreferences?.customAccentColorHex
        ?? UserDefaults.standard.string(forKey: "com.ampwave.customAccent")).map { Color(hex: $0) },
      customCard: (userPreferences?.customCardBackgroundColorHex
        ?? UserDefaults.standard.string(forKey: "com.ampwave.customCard")).map { Color(hex: $0) },
      customPrimaryText: (userPreferences?.customPrimaryTextColorHex
        ?? UserDefaults.standard.string(forKey: "com.ampwave.customPrimaryText")).map {
          Color(hex: $0)
        },
      customSecondaryText: (userPreferences?.customSecondaryTextColorHex
        ?? UserDefaults.standard.string(forKey: "com.ampwave.customSecondaryText")).map {
          Color(hex: $0)
        }
    )
  }

  var accentColor: Color { themeConfig.accent }
  var backgroundColor: Color { themeConfig.background }
  // cardBackgroundColor is intentionally NOT gated on coloredSurfaces.
  // Only SongCard / ArtistCard / AlbumCard check that flag for their own
  // backgrounds. List-row backgrounds in Settings, sheets, and the player
  // must stay consistent regardless of the toggle.
  var cardBackgroundColor: Color { themeConfig.cardBackground }
  var primaryTextColor: Color { themeConfig.primaryText }
  var secondaryTextColor: Color { themeConfig.secondaryText }

  var colorScheme: ColorScheme? {
    if currentTheme == .custom {
      if let prefs = userPreferences { return prefs.customColorScheme }
      let raw = UserDefaults.standard.string(forKey: "com.ampwave.customColorScheme")
      return raw == "light" ? .light : .dark
    }
    switch currentTheme {
    case .light, .catppuccinLatte, .roseGold, .kanagawaLotus, .nordLight, .everforestLight:
      return .light
    case .dark, .oled,
         .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha,
         .dracula,
         .nordDark, .everforestDark, .kanagawaWave:
      return .dark
    default: return nil  // .ampwave and .custom follow the system
    }
  }

  private init() {}
}

extension Color {
  func lighter(by amount: CGFloat = 0.2) -> Color {
    #if canImport(UIKit)
      let uiColor = UIColor(self)
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
      return Color(
        red: min(r + amount, 1), green: min(g + amount, 1), blue: min(b + amount, 1), opacity: a)
    #else
      return self
    #endif
  }

  func darker(by amount: CGFloat = 0.2) -> Color {
    #if canImport(UIKit)
      let uiColor = UIColor(self)
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
      return Color(
        red: max(r - amount, 0), green: max(g - amount, 0), blue: max(b - amount, 0), opacity: a)
    #else
      return self
    #endif
  }
}

@Model
final class UserPreferences: Identifiable {
  @Attribute(.unique) var id: UUID

  var crossfadeEnabled: Bool
  var crossfadeDuration: Double
  var gaplessPlayback: Bool
  var normalizeVolume: Bool
  var defaultShuffleModeRaw: String
  var defaultRepeatModeRaw: String

  var showNowPlayingOnLaunch: Bool
  var expandPlayerAutomatically: Bool
  var showLyricsByDefault: Bool = false
  var artworkQualityRaw: String

  var autoFetchMetadata: Bool
  /// Opt-in library-wide enrichment for artist biographies/photos and album
  /// details. Song-level online metadata remains controlled separately above.
  var autoFetchArtistAlbumInfo: Bool = false
  var autoFetchLyrics: Bool
  var wordSyncedLyricsEnabled: Bool = false
  /// Opt-in because animated Apple Music artwork uses an unofficial online
  /// lookup and may download video while the album is playing.
  var animatedArtworkEnabled: Bool = false
  var copyMusicToStorage: Bool = true
  /// When enabled, removing a referenced song from Ampwave also deletes the
  /// external audio file. Defaults to false because this is destructive and
  /// may affect folders synchronized with another device.
  var deleteReferencedFilesOnRemoval: Bool = false
  var preferOnlineArtwork: Bool
  var organizeByAlbum: Bool

  /// True when the app may make network requests: online, and the user hasn't
  /// turned on Offline Mode. Checked at the network choke points rather than at
  /// each feature, so a new caller can't silently bypass it.
  @MainActor
  static var networkAllowed: Bool {
    guard NetworkMonitor.shared.isOnline else { return false }
    guard let context = sharedContextForNetworkCheck else { return true }
    return !getOrCreate(in: context).isOfflineMode
  }

  /// Set once at launch so `networkAllowed` can be read without plumbing a
  /// context through every service.
  @MainActor
  @ObservationIgnored
  static var sharedContextForNetworkCheck: ModelContext?

  var isOfflineMode: Bool
  var lastSyncDate: Date?

  var showPlaybackNotifications: Bool
  var showLyricsNotifications: Bool

  var enableRecommendations: Bool
  var recommendationSourcesRaw: [String]

  // Theme Settings
  var selectedThemeRaw: String? {
    get { _selectedThemeRaw ?? UserDefaults.standard.string(forKey: "com.ampwave.selectedTheme") }
    set {
      _selectedThemeRaw = newValue
      if let newValue = newValue {
        UserDefaults.standard.set(newValue, forKey: "com.ampwave.selectedTheme")
      }
      save()
    }
  }
  @Attribute(originalName: "selectedThemeRaw") var _selectedThemeRaw: String?

  var customAccentColorHex: String? {
    get { _customAccentColorHex }
    set {
      _customAccentColorHex = newValue
      save()
    }
  }
  @Attribute(originalName: "customAccentColorHex") var _customAccentColorHex: String?

  var customBackgroundColorHex: String? {
    get { _customBackgroundColorHex }
    set {
      _customBackgroundColorHex = newValue
      save()
    }
  }
  @Attribute(originalName: "customBackgroundColorHex") var _customBackgroundColorHex: String?

  var customCardBackgroundColorHex: String? {
    get { _customCardBackgroundColorHex }
    set {
      _customCardBackgroundColorHex = newValue
      save()
    }
  }
  @Attribute(originalName: "customCardBackgroundColorHex") var _customCardBackgroundColorHex:
    String?

  var customPrimaryTextColorHex: String? {
    get { _customPrimaryTextColorHex }
    set {
      _customPrimaryTextColorHex = newValue
      save()
    }
  }
  var _customPrimaryTextColorHex: String?

  var customSecondaryTextColorHex: String? {
    get { _customSecondaryTextColorHex }
    set {
      _customSecondaryTextColorHex = newValue
      save()
    }
  }
  var _customSecondaryTextColorHex: String?

  var fullArtworkBackground: Bool? {
    get {
      _fullArtworkBackground
        ?? UserDefaults.standard.bool(forKey: "com.ampwave.fullArtworkBackground")
    }
    set {
      _fullArtworkBackground = newValue
      UserDefaults.standard.set(newValue ?? true, forKey: "com.ampwave.fullArtworkBackground")
      save()
    }
  }
  @Attribute(originalName: "fullArtworkBackground") var _fullArtworkBackground: Bool?

  var openPlayerGlassBackground: Bool? {
    get {
      _openPlayerGlassBackground
        ?? UserDefaults.standard.bool(forKey: "com.ampwave.openPlayerGlassBackground")
    }
    set {
      _openPlayerGlassBackground = newValue
      UserDefaults.standard.set(newValue ?? true, forKey: "com.ampwave.openPlayerGlassBackground")
      save()
    }
  }
  @Attribute(originalName: "openPlayerGlassBackground") var _openPlayerGlassBackground: Bool?

  var wavyPlayerSlider: Bool? {
    get {
      _wavyPlayerSlider
        ?? UserDefaults.standard.object(forKey: "com.ampwave.wavyPlayerSlider") as? Bool
    }
    set {
      _wavyPlayerSlider = newValue
      UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.wavyPlayerSlider")
      save()
    }
  }
  @Attribute(originalName: "wavyPlayerSlider") var _wavyPlayerSlider: Bool?

  var coloredSurfaces: Bool? {
    get {
      _coloredSurfaces ?? UserDefaults.standard.bool(forKey: "com.ampwave.coloredSurfaces")
    }
    set {
      _coloredSurfaces = newValue
      UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.coloredSurfaces")
      save()
    }
  }
  @Attribute(originalName: "fullAppBackground") var _coloredSurfaces: Bool?

  var showFullArtworkGradient: Bool? {
    get {
      _showFullArtworkGradient
        ?? UserDefaults.standard.bool(forKey: "com.ampwave.showFullArtworkGradient")
    }
    set {
      _showFullArtworkGradient = newValue
      UserDefaults.standard.set(newValue ?? true, forKey: "com.ampwave.showFullArtworkGradient")
      save()
    }
  }
  @Attribute(originalName: "showFullArtworkGradient") var _showFullArtworkGradient: Bool?

  var miniPlayerFloating: Bool? {
    get {
      _miniPlayerFloating ?? UserDefaults.standard.bool(forKey: "com.ampwave.miniPlayerFloating")
    }
    set {
      _miniPlayerFloating = newValue
      UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.miniPlayerFloating")
      save()
    }
  }
  @Attribute(originalName: "miniPlayerFloating") var _miniPlayerFloating: Bool?

  var coverArtAccentPlayer: Bool? {
    get {
      _coverArtAccentPlayer
        ?? UserDefaults.standard.object(forKey: "com.ampwave.coverArtAccentPlayer") as? Bool
    }
    set {
      _coverArtAccentPlayer = newValue
      UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.coverArtAccentPlayer")
      save()
    }
  }
  @Attribute(originalName: "coverArtAccentPlayer") var _coverArtAccentPlayer: Bool?

  var fullScreenArtworkExpanded: Bool? {
    get {
      _fullScreenArtworkExpanded
        ?? UserDefaults.standard.object(forKey: "com.ampwave.fullScreenArtworkExpanded") as? Bool
    }
    set {
      _fullScreenArtworkExpanded = newValue
      UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.fullScreenArtworkExpanded")
      save()
    }
  }
  @Attribute(originalName: "fullScreenArtworkExpanded") var _fullScreenArtworkExpanded: Bool?
  var isPremiumUser: Bool?
  var customColorSchemeRaw: String? {
    get {
      _customColorSchemeRaw ?? UserDefaults.standard.string(forKey: "com.ampwave.customColorScheme")
    }
    set {
      _customColorSchemeRaw = newValue
      UserDefaults.standard.set(newValue, forKey: "com.ampwave.customColorScheme")
      save()
    }
  }
  @Attribute(originalName: "customColorSchemeRaw") var _customColorSchemeRaw: String?

  var defaultShuffleMode: ShuffleMode {
    get { ShuffleMode(rawValue: defaultShuffleModeRaw) ?? .off }
    set { defaultShuffleModeRaw = newValue.rawValue }
  }

  var defaultRepeatMode: RepeatMode {
    get { RepeatMode(rawValue: defaultRepeatModeRaw) ?? .off }
    set { defaultRepeatModeRaw = newValue.rawValue }
  }

  var artworkQuality: ArtworkQuality {
    get { ArtworkQuality(rawValue: artworkQualityRaw) ?? .high }
    set { artworkQualityRaw = newValue.rawValue }
  }

  var recommendationSources: [RecommendationSource] {
    get { recommendationSourcesRaw.compactMap { RecommendationSource(rawValue: $0) } }
    set { recommendationSourcesRaw = newValue.map { $0.rawValue } }
  }

  var selectedTheme: AppTheme {
    get { AppTheme.resolved(fromStoredRaw: selectedThemeRaw ?? AppTheme.ampwave.rawValue) }
    set {
      selectedThemeRaw = newValue.rawValue
      save()
    }
  }

  func save() {
    // Explicitly update singleton
    ThemeManager.shared.userPreferences = self
    // Try to save to SwiftData
    try? modelContext?.save()

    // Save to UserDefaults for immediate restoration on next launch
    UserDefaults.standard.set(selectedThemeRaw, forKey: "com.ampwave.selectedTheme")
    UserDefaults.standard.set(customAccentColorHex, forKey: "com.ampwave.customAccent")
    UserDefaults.standard.set(customBackgroundColorHex, forKey: "com.ampwave.customBackground")
    UserDefaults.standard.set(customCardBackgroundColorHex, forKey: "com.ampwave.customCard")
    UserDefaults.standard.set(customPrimaryTextColorHex, forKey: "com.ampwave.customPrimaryText")
    UserDefaults.standard.set(
      customSecondaryTextColorHex, forKey: "com.ampwave.customSecondaryText")
    UserDefaults.standard.set(customColorSchemeRaw, forKey: "com.ampwave.customColorScheme")
    UserDefaults.standard.set(
      fullArtworkBackground ?? false, forKey: "com.ampwave.fullArtworkBackground")
    UserDefaults.standard.set(
      openPlayerGlassBackground ?? true, forKey: "com.ampwave.openPlayerGlassBackground")
    UserDefaults.standard.set(
      wavyPlayerSlider ?? false, forKey: "com.ampwave.wavyPlayerSlider")
    UserDefaults.standard.set(
      coloredSurfaces ?? true, forKey: "com.ampwave.coloredSurfaces")
    UserDefaults.standard.set(
      showFullArtworkGradient ?? true, forKey: "com.ampwave.showFullArtworkGradient")
    UserDefaults.standard.set(miniPlayerFloating ?? false, forKey: "com.ampwave.miniPlayerFloating")
    UserDefaults.standard.set(
      fullScreenArtworkExpanded ?? false, forKey: "com.ampwave.fullScreenArtworkExpanded")
    UserDefaults.standard.set(
      coverArtAccentPlayer ?? false, forKey: "com.ampwave.coverArtAccentPlayer")
  }

  var customColorScheme: ColorScheme? {
    get {
      guard let raw = customColorSchemeRaw else { return nil }
      return raw == "light" ? .light : .dark
    }
    set {
      customColorSchemeRaw = newValue == .light ? "light" : "dark"
    }
  }

  init() {
    self.id = UUID()

    // If the user configured these during onboarding, honour their choices.
    // Keys are set by OnboardingView before UserPreferences is first created.
    let ud = UserDefaults.standard
    func onboardingBool(_ key: String, default fallback: Bool) -> Bool {
      ud.object(forKey: key) != nil ? ud.bool(forKey: key) : fallback
    }

    self.crossfadeEnabled = false
    self.crossfadeDuration = 2.0
    self.gaplessPlayback = onboardingBool("com.ampwave.onboarding.gaplessPlayback", default: true)
    self.normalizeVolume = onboardingBool("com.ampwave.onboarding.normalizeVolume", default: false)
    self.defaultShuffleModeRaw = ShuffleMode.off.rawValue
    self.defaultRepeatModeRaw = RepeatMode.off.rawValue
    self.showNowPlayingOnLaunch = false
    self.expandPlayerAutomatically = false
    self.showLyricsByDefault = false
    self.artworkQualityRaw = ArtworkQuality.high.rawValue
    self.autoFetchMetadata = onboardingBool("com.ampwave.onboarding.autoFetchMetadata", default: true)
    self.autoFetchArtistAlbumInfo = false
    self.autoFetchLyrics = onboardingBool("com.ampwave.onboarding.autoFetchLyrics", default: true)
    self.wordSyncedLyricsEnabled = true
    self.animatedArtworkEnabled = false
    self.copyMusicToStorage = onboardingBool("com.ampwave.onboarding.copyToStorage", default: true)
    self.deleteReferencedFilesOnRemoval = false
    self.preferOnlineArtwork = false
    self.organizeByAlbum = true
    self.isOfflineMode = false
    self.showPlaybackNotifications = true
    self.showLyricsNotifications = false
    self.enableRecommendations = true
    self.recommendationSourcesRaw = [
      RecommendationSource.listeningHistory.rawValue, RecommendationSource.genres.rawValue,
      RecommendationSource.similarArtists.rawValue,
    ]
    self.selectedThemeRaw = AppTheme.ampwave.rawValue
    self.fullArtworkBackground = true
    self.openPlayerGlassBackground = true
    self.wavyPlayerSlider = false
    self.coloredSurfaces = true
    self.showFullArtworkGradient = true
    self.miniPlayerFloating = false
    self.fullScreenArtworkExpanded = false
    self.coverArtAccentPlayer = false
    self.isPremiumUser = true
    self.customColorSchemeRaw = "dark"
    // Don't overwrite a theme the user chose during onboarding — the computed
    // property getter falls back to UserDefaults, so leaving _selectedThemeRaw
    // nil here means it will correctly read the onboarding-written value.
    self._selectedThemeRaw = nil
  }

  static func getOrCreate(in modelContext: ModelContext) -> UserPreferences {
    do {
      var descriptor = FetchDescriptor<UserPreferences>()
      descriptor.fetchLimit = 1
      if let existing = try modelContext.fetch(descriptor).first {
        // Ensure new fields have defaults if they were migrated as nil
        if existing.selectedThemeRaw == "midnightBlue"
          || UserDefaults.standard.string(forKey: "com.ampwave.selectedTheme") == "midnightBlue"
        {
          existing.selectedThemeRaw = AppTheme.dark.rawValue
          UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: "com.ampwave.selectedTheme")
        }
        if existing.selectedThemeRaw == nil {
          existing.selectedThemeRaw = AppTheme.ampwave.rawValue
        }
        if existing.fullArtworkBackground == nil { existing.fullArtworkBackground = true }
        if existing.openPlayerGlassBackground == nil { existing.openPlayerGlassBackground = true }
        if existing.wavyPlayerSlider == nil { existing.wavyPlayerSlider = false }
        if existing.coloredSurfaces == nil {
          existing.coloredSurfaces = UserDefaults.standard.object(forKey: "com.ampwave.coloredSurfaces") as? Bool ?? true
        }
        if existing.showFullArtworkGradient == nil { existing.showFullArtworkGradient = true }
        if existing.miniPlayerFloating == nil { existing.miniPlayerFloating = false }
        if existing.fullScreenArtworkExpanded == nil { existing.fullScreenArtworkExpanded = false }
        if existing.coverArtAccentPlayer == nil { existing.coverArtAccentPlayer = false }
        if existing.wordSyncedLyricsEnabled == nil { existing.wordSyncedLyricsEnabled = true }
        if existing.copyMusicToStorage == nil { existing.copyMusicToStorage = true }
        if existing.isPremiumUser == nil { existing.isPremiumUser = true }
        if existing.customColorSchemeRaw == nil { existing.customColorSchemeRaw = "dark" }

        ThemeManager.shared.userPreferences = existing
        return existing
      }
    } catch {}

    let newPreferences = UserPreferences()
    modelContext.insert(newPreferences)
    try? modelContext.save()
    ThemeManager.shared.userPreferences = newPreferences
    return newPreferences
  }
}

// MARK: - ThemeManager Extensions
extension ThemeManager {
  /// Kept as a separate decision point for themes that may opt back into
  /// completely system-owned chrome in the future.
  var usesSystemAppearance: Bool { false }

  var fullArtworkBackground: Bool {
    userPreferences?.fullArtworkBackground
      ?? UserDefaults.standard.bool(forKey: "com.ampwave.fullArtworkBackground")
  }
  var openPlayerGlassBackground: Bool {
    userPreferences?.openPlayerGlassBackground
      ?? UserDefaults.standard.object(forKey: "com.ampwave.openPlayerGlassBackground") as? Bool
      ?? true
  }
  var coloredSurfaces: Bool {
    userPreferences?.coloredSurfaces
      ?? UserDefaults.standard.bool(forKey: "com.ampwave.coloredSurfaces")
  }
  var showFullArtworkGradient: Bool {
    userPreferences?.showFullArtworkGradient
      ?? UserDefaults.standard.object(forKey: "com.ampwave.showFullArtworkGradient") as? Bool
      ?? true
  }
  var miniPlayerFloating: Bool {
    userPreferences?.miniPlayerFloating
      ?? UserDefaults.standard.bool(forKey: "com.ampwave.miniPlayerFloating")
  }
  var fullScreenArtworkExpanded: Bool {
    userPreferences?.fullScreenArtworkExpanded
      ?? UserDefaults.standard.object(forKey: "com.ampwave.fullScreenArtworkExpanded") as? Bool
      ?? false
  }
  var coverArtAccentPlayer: Bool {
    userPreferences?.coverArtAccentPlayer
      ?? UserDefaults.standard.object(forKey: "com.ampwave.coverArtAccentPlayer") as? Bool
      ?? false
  }
}
