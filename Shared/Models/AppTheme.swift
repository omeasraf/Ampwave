//
//  AppTheme.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/16/26.
//


internal import SwiftUI

struct ThemeConfig {
    let background: Color
    let secondaryBackground: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let isDark: Bool
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system
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
        case .system: return "System"
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

    var isPremium: Bool {
        return false
    }

    func colors(isDark: Bool, customBackground: Color? = nil, customAccent: Color? = nil) -> ThemeConfig {
        let actualIsDark: Bool
        switch self {
        case .system: actualIsDark = isDark
        case .light, .catppuccinLatte, .roseGold: actualIsDark = false
        case .dark, .oled, .midnightBlue, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula: actualIsDark = true
        case .custom: actualIsDark = isDark
        }

        let bg: Color
        let accent: Color

        switch self {
        case .system:
            bg = actualIsDark ? Color(white: 0.05) : Color(white: 0.95)
            accent = Color("AccentColor")
        case .light:
            bg = .white
            accent = Color("AccentColor")
        case .dark:
            bg = Color(white: 0.1)
            accent = Color("AccentColor")
        case .oled:
            bg = .black
            accent = Color("AccentColor")
        case .roseGold:
            bg = Color(red: 0.98, green: 0.92, blue: 0.94)
            accent = .pink
        case .midnightBlue:
            bg = Color(red: 8/255.0, green: 17/255.0, blue: 59/255.0)
            accent = .blue
        case .catppuccinLatte:
            bg = Color(red: 239/255.0, green: 241/255.0, blue: 245/255.0)
            accent = Color(red: 136/255.0, green: 57/255.0, blue: 239/255.0)
        case .catppuccinFrappe:
            bg = Color(red: 48/255.0, green: 52/255.0, blue: 70/255.0)
            accent = Color(red: 202/255.0, green: 158/255.0, blue: 230/255.0)
        case .catppuccinMacchiato:
            bg = Color(red: 36/255.0, green: 39/255.0, blue: 58/255.0)
            accent = Color(red: 198/255.0, green: 160/255.0, blue: 246/255.0)
        case .catppuccinMocha:
            bg = Color(red: 30/255.0, green: 30/255.0, blue: 46/255.0)
            accent = Color(red: 203/255.0, green: 166/255.0, blue: 247/255.0)
        case .dracula:
            bg = Color(red: 40/255.0, green: 42/255.0, blue: 54/255.0)
            accent = Color(red: 189/255.0, green: 147/255.0, blue: 249/255.0)
        case .custom:
            bg = customBackground ?? (actualIsDark ? .black : .white)
            accent = customAccent ?? Color("AccentColor")
        }

        let secondaryBg = actualIsDark ? bg.lighter(by: 0.05) : bg.darker(by: 0.05)
        let primaryText = actualIsDark ? Color.white : Color.black
        let secondaryText = actualIsDark ? Color.white.opacity(0.7) : Color.black.opacity(0.7)

        return ThemeConfig(
            background: bg,
            secondaryBackground: secondaryBg,
            accent: accent,
            primaryText: primaryText,
            secondaryText: secondaryText,
            isDark: actualIsDark
        )
    }

    // Deprecated methods for backward compatibility during transition
    func backgroundColor(isDark: Bool) -> Color? {
        return colors(isDark: isDark).background
    }

    func accentColor() -> Color? {
        return colors(isDark: false).accent
    }
    
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light, .catppuccinLatte: return .light
        case .dark, .oled, .midnightBlue, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha, .dracula: return .dark
        case .roseGold: return .light
        default: return nil
        }
    }
}
