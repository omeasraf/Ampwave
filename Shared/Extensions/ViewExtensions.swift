//
//  ViewExtensions.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/16/26.
//

internal import SwiftUI

private struct ThemeConfigKey: EnvironmentKey {
    static let defaultValue: ThemeConfig = AppTheme.system.colors(isDark: false)
}

extension EnvironmentValues {
    var theme: ThemeConfig {
        get { self[ThemeConfigKey.self] }
        set { self[ThemeConfigKey.self] = newValue }
    }
}

extension View {
    func subtitle(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            self
//            Text(text)
//                .font(.caption)
//                .foregroundColor(.secondary)
        }
    }

    func themeAware(_ preferences: UserPreferences) -> some View {
        modifier(ThemeModifier(preferences: preferences))
    }
}

struct ThemeModifier: ViewModifier {
    @Bindable var preferences: UserPreferences
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        let isDark = preferences.selectedTheme.preferredColorScheme == .dark || (preferences.selectedTheme == .system && colorScheme == .dark)
        
        let customBg = preferences.customBackgroundColorHex.flatMap { Color(hex: $0) }
        let customAccent = preferences.customAccentColorHex.flatMap { Color(hex: $0) }
        
        let themeConfig = preferences.selectedTheme.colors(
            isDark: isDark,
            customBackground: customBg,
            customAccent: customAccent
        )

        content
            .environment(\.theme, themeConfig)
            .tint(themeConfig.accent)
            .accentColor(themeConfig.accent)
            .preferredColorScheme(preferences.selectedTheme.preferredColorScheme)
            .scrollContentBackground(.hidden)
            .background(themeConfig.background.ignoresSafeArea())
            // Ensure toolbars are also themed or transparent
        #if os(iOS)
            .toolbarBackground(themeConfig.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        #endif
    }
}
