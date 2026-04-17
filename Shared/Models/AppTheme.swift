//
//  AppTheme.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/16/26.
//


internal import SwiftUI

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

    func backgroundColor(isDark: Bool) -> Color? {
        switch self {
        case .system: return nil
        case .light: return .white
        case .dark: return Color(white: 0.1)
        case .oled: return .black
        case .roseGold: return Color(red: 0.98, green: 0.92, blue: 0.94)
        case .midnightBlue: return Color(red: 8/255.0, green: 17/255.0, blue: 59/255.0)
        case .catppuccinLatte: return Color(red: 239/255.0, green: 241/255.0, blue: 245/255.0)
        case .catppuccinFrappe: return Color(red: 48/255.0, green: 52/255.0, blue: 70/255.0)
        case .catppuccinMacchiato: return Color(red: 36/255.0, green: 39/255.0, blue: 58/255.0)
        case .catppuccinMocha: return Color(red: 30/255.0, green: 30/255.0, blue: 46/255.0)
        case .dracula: return Color(red: 40/255.0, green: 42/255.0, blue: 54/255.0)
        case .custom: return nil
        }
    }

    func accentColor() -> Color? {
        switch self {
        case .system, .light, .dark, .oled: return Color("AccentColor")
        case .roseGold: return .pink
        case .midnightBlue: return .blue
        case .catppuccinLatte: return Color(red: 136/255.0, green: 57/255.0, blue: 239/255.0) // Mauve
        case .catppuccinFrappe: return Color(red: 202/255.0, green: 158/255.0, blue: 230/255.0) // Mauve
        case .catppuccinMacchiato: return Color(red: 198/255.0, green: 160/255.0, blue: 246/255.0) // Mauve
        case .catppuccinMocha: return Color(red: 203/255.0, green: 166/255.0, blue: 247/255.0) // Mauve
        case .dracula: return Color(red: 189/255.0, green: 147/255.0, blue: 249/255.0)
        case .custom: return nil
        }
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
