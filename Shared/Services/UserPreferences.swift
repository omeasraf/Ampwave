//
//  UserPreferences.swift
//  Ampwave
//
//  User preferences and app settings.
//

import Foundation
import SwiftData

internal import SwiftUI
import SwiftData

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
    case midnightBlue
    case catppuccinLatte
    case catppuccinFrappe
    case catppuccinMacchiato
    case catppuccinMocha
    case dracula
    case custom
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ampwave: return "Ampwave"
        case .light: return "Light"
        case .dark: return "Dark"
        case .oled: return "OLED"
        case .roseGold: return "Rose Gold"
        case .midnightBlue: return "Midnight Blue"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .catppuccinFrappe: return "Catppuccin Frappé"
        case .catppuccinMacchiato: return "Catppuccin Macchiato"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .dracula: return "Dracula"
        case .custom: return "Custom"
        }
    }
    
    func colors(isDark: Bool, customBackground: Color? = nil, customAccent: Color? = nil, customCard: Color? = nil) -> ThemeConfig {
        let actualIsDark: Bool
        switch self {
        case .ampwave: actualIsDark = isDark
        case .light, .catppuccinLatte, .roseGold: actualIsDark = false
        case .dark, .oled, .midnightBlue, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula: actualIsDark = true
        case .custom: actualIsDark = isDark
        }

        let bg: Color
        let accent: Color
        let card: Color?

        switch self {
        case .ampwave:
            bg = actualIsDark ? Color(white: 0.05) : Color(white: 0.95)
            accent = Color.pink
            card = nil
        case .light:
            bg = .white
            accent = Color.pink
            card = Color(white: 0.95)
        case .dark:
            bg = Color(white: 0.1)
            accent = Color.pink
            card = Color(white: 0.15)
        case .oled:
            bg = .black
            accent = Color.pink
            card = Color(white: 0.1)
        case .roseGold:
            bg = Color(red: 0.98, green: 0.92, blue: 0.94)
            accent = .pink
            card = Color(red: 1.0, green: 0.96, blue: 0.97)
        case .midnightBlue:
            bg = Color(red: 8/255.0, green: 17/255.0, blue: 59/255.0)
            accent = .blue
            card = Color(red: 15/255.0, green: 25/255.0, blue: 80/255.0)
        case .catppuccinLatte:
            bg = Color(red: 239/255.0, green: 241/255.0, blue: 245/255.0)
            accent = Color(red: 136/255.0, green: 57/255.0, blue: 239/255.0)
            card = Color(red: 230/255.0, green: 233/255.0, blue: 239/255.0)
        case .catppuccinFrappe:
            bg = Color(red: 48/255.0, green: 52/255.0, blue: 70/255.0)
            accent = Color(red: 202/255.0, green: 158/255.0, blue: 230/255.0)
            card = Color(red: 65/255.0, green: 69/255.0, blue: 89/255.0)
        case .catppuccinMacchiato:
            bg = Color(red: 36/255.0, green: 39/255.0, blue: 58/255.0)
            accent = Color(red: 198/255.0, green: 160/255.0, blue: 246/255.0)
            card = Color(red: 54/255.0, green: 58/255.0, blue: 79/255.0)
        case .catppuccinMocha:
            bg = Color(red: 30/255.0, green: 30/255.0, blue: 46/255.0)
            accent = Color(red: 203/255.0, green: 166/255.0, blue: 247/255.0)
            card = Color(red: 49/255.0, green: 50/255.0, blue: 68/255.0)
        case .dracula:
            bg = Color(red: 40/255.0, green: 42/255.0, blue: 54/255.0)
            accent = Color(red: 189/255.0, green: 147/255.0, blue: 249/255.0)
            card = Color(red: 68/255.0, green: 71/255.0, blue: 90/255.0)
        case .custom:
            bg = customBackground ?? (actualIsDark ? .black : .white)
            accent = customAccent ?? Color.pink
            card = customCard ?? (actualIsDark ? Color(white: 0.1) : Color(white: 0.9))
        }

        let actualCard = card ?? (actualIsDark ? bg.lighter(by: 0.05) : bg.darker(by: 0.05))
        let primaryText = actualIsDark ? Color.white : Color.black
        let secondaryText = actualIsDark ? Color.white.opacity(0.7) : Color.black.opacity(0.7)

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
        return AppTheme(rawValue: raw ?? "") ?? .ampwave
    }
    
    var themeConfig: ThemeConfig {
        currentTheme.colors(
            isDark: ampwaveColorScheme == .dark,
            customBackground: (userPreferences?.customBackgroundColorHex ?? UserDefaults.standard.string(forKey: "com.ampwave.customBackground")).map { Color(hex: $0) },
            customAccent: (userPreferences?.customAccentColorHex ?? UserDefaults.standard.string(forKey: "com.ampwave.customAccent")).map { Color(hex: $0) },
            customCard: (userPreferences?.customCardBackgroundColorHex ?? UserDefaults.standard.string(forKey: "com.ampwave.customCard")).map { Color(hex: $0) }
        )
    }
    
    var accentColor: Color { themeConfig.accent }
    var backgroundColor: Color { themeConfig.background }
    var cardBackgroundColor: Color { themeConfig.cardBackground }
    
    var colorScheme: ColorScheme? {
        if currentTheme == .custom {
            if let prefs = userPreferences { return prefs.customColorScheme }
            let raw = UserDefaults.standard.string(forKey: "com.ampwave.customColorScheme")
            return raw == "light" ? .light : .dark
        }
        switch currentTheme {
        case .light, .catppuccinLatte, .roseGold: return .light
        case .dark, .oled, .midnightBlue, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula: return .dark
        default: return nil
        }
    }
    
    private init() {}
}

extension Color {
    func lighter(by amount: CGFloat = 0.2) -> Color {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: min(r + amount, 1), green: min(g + amount, 1), blue: min(b + amount, 1), opacity: a)
        #else
        return self
        #endif
    }
    
    func darker(by amount: CGFloat = 0.2) -> Color {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: max(r - amount, 0), green: max(g - amount, 0), blue: max(b - amount, 0), opacity: a)
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
  var showLyricsByDefault: Bool
  var artworkQualityRaw: String

  var autoFetchMetadata: Bool
  var autoFetchLyrics: Bool
  var preferOnlineArtwork: Bool
  var organizeByAlbum: Bool

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
    set { _customAccentColorHex = newValue; save() }
  }
  @Attribute(originalName: "customAccentColorHex") var _customAccentColorHex: String?

  var customBackgroundColorHex: String? {
    get { _customBackgroundColorHex }
    set { _customBackgroundColorHex = newValue; save() }
  }
  @Attribute(originalName: "customBackgroundColorHex") var _customBackgroundColorHex: String?

  var customCardBackgroundColorHex: String? {
    get { _customCardBackgroundColorHex }
    set { _customCardBackgroundColorHex = newValue; save() }
  }
  @Attribute(originalName: "customCardBackgroundColorHex") var _customCardBackgroundColorHex: String?

  var fullArtworkBackground: Bool? {
    get { _fullArtworkBackground ?? UserDefaults.standard.bool(forKey: "com.ampwave.fullArtworkBackground") }
    set { 
        _fullArtworkBackground = newValue
        UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.fullArtworkBackground")
        save() 
    }
  }
  @Attribute(originalName: "fullArtworkBackground") var _fullArtworkBackground: Bool?

  var showFullArtworkGradient: Bool? {
    get { _showFullArtworkGradient ?? UserDefaults.standard.bool(forKey: "com.ampwave.showFullArtworkGradient") }
    set { 
        _showFullArtworkGradient = newValue
        UserDefaults.standard.set(newValue ?? true, forKey: "com.ampwave.showFullArtworkGradient")
        save() 
    }
  }
  @Attribute(originalName: "showFullArtworkGradient") var _showFullArtworkGradient: Bool?

  var miniPlayerFloating: Bool? {
    get { _miniPlayerFloating ?? UserDefaults.standard.bool(forKey: "com.ampwave.miniPlayerFloating") }
    set { 
        _miniPlayerFloating = newValue
        UserDefaults.standard.set(newValue ?? false, forKey: "com.ampwave.miniPlayerFloating")
        save() 
    }
  }
  @Attribute(originalName: "miniPlayerFloating") var _miniPlayerFloating: Bool?
  var isPremiumUser: Bool?
  var customColorSchemeRaw: String? {
    get { _customColorSchemeRaw ?? UserDefaults.standard.string(forKey: "com.ampwave.customColorScheme") }
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
    get { AppTheme(rawValue: selectedThemeRaw ?? AppTheme.ampwave.rawValue) ?? .ampwave }
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
    UserDefaults.standard.set(customColorSchemeRaw, forKey: "com.ampwave.customColorScheme")
    UserDefaults.standard.set(fullArtworkBackground ?? false, forKey: "com.ampwave.fullArtworkBackground")
    UserDefaults.standard.set(showFullArtworkGradient ?? true, forKey: "com.ampwave.showFullArtworkGradient")
    UserDefaults.standard.set(miniPlayerFloating ?? false, forKey: "com.ampwave.miniPlayerFloating")
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
    self.crossfadeEnabled = false
    self.crossfadeDuration = 2.0
    self.gaplessPlayback = true
    self.normalizeVolume = false
    self.defaultShuffleModeRaw = ShuffleMode.off.rawValue
    self.defaultRepeatModeRaw = RepeatMode.off.rawValue
    self.showNowPlayingOnLaunch = false
    self.expandPlayerAutomatically = false
    self.showLyricsByDefault = false
    self.artworkQualityRaw = ArtworkQuality.high.rawValue
    self.autoFetchMetadata = true
    self.autoFetchLyrics = true
    self.preferOnlineArtwork = true
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
    self.fullArtworkBackground = false
    self.showFullArtworkGradient = true
    self.miniPlayerFloating = false
    self.isPremiumUser = true
    self.customColorSchemeRaw = "dark"
  }

  static func getOrCreate(in modelContext: ModelContext) -> UserPreferences {
    do {
      var descriptor = FetchDescriptor<UserPreferences>()
      descriptor.fetchLimit = 1
      if let existing = try modelContext.fetch(descriptor).first {
        // Ensure new fields have defaults if they were migrated as nil
        if existing.selectedThemeRaw == nil { existing.selectedThemeRaw = AppTheme.ampwave.rawValue }
        if existing.fullArtworkBackground == nil { existing.fullArtworkBackground = false }
        if existing.showFullArtworkGradient == nil { existing.showFullArtworkGradient = true }
        if existing.miniPlayerFloating == nil { existing.miniPlayerFloating = false }
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
    var fullArtworkBackground: Bool { userPreferences?.fullArtworkBackground ?? false }
    var showFullArtworkGradient: Bool { userPreferences?.showFullArtworkGradient ?? true }
    var miniPlayerFloating: Bool { userPreferences?.miniPlayerFloating ?? false }
}
