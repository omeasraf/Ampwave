//
//  ThemeSettingsView.swift
//  Ampwave
//

internal import SwiftUI
import SwiftData

struct ThemeSettingsView: View {
    @Bindable var preferences: UserPreferences
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) private var theme
    
    @State private var accentColor: Color = .blue
    @State private var backgroundColor: Color = .black
    
    var body: some View {
        List {
            Section("App Theme") {
                ForEach(AppTheme.allCases) { theme in
                    HStack {
                        Button {
                            preferences.selectedTheme = theme
                            save()
                        } label: {
                            HStack {
                                Text(theme.displayName)
                                Spacer()
                                if theme.isPremium && !(preferences.isPremiumUser ?? false) {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if preferences.selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(currentAccentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(theme.isPremium && !(preferences.isPremiumUser ?? true))
                    }
                }
            }
            
            Section("Colors") {
                ColorPicker("Accent Color", selection: $accentColor)
                    .onChange(of: accentColor) { _, newValue in
                        preferences.customAccentColorHex = newValue.toHex()
                        save()
                    }
                
                Button("Reset Accent Color") {
                    preferences.customAccentColorHex = nil
                    updateColorsFromPreferences()
                    save()
                }
                .foregroundStyle(.red)
                
                if preferences.selectedTheme == .custom {
                    ColorPicker("Background Color", selection: $backgroundColor)
                        .onChange(of: backgroundColor) { _, newValue in
                            preferences.customBackgroundColorHex = newValue.toHex()
                            save()
                        }
                }
            }
            
            Section("Player Customization") {
                Toggle("Full Artwork Background", isOn: $preferences.fullArtworkBackground.withDefault(false))
                    .onChange(of: preferences.fullArtworkBackground) { save() }
                Text("Make artwork fill the top of the player with a blur effect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if preferences.fullArtworkBackground ?? false {
                    Toggle("Full Artwork Gradient", isOn: $preferences.showFullArtworkGradient.withDefault(true))
                        .onChange(of: preferences.showFullArtworkGradient) { save() }
                }
                
                Toggle("Floating Mini Player", isOn: $preferences.miniPlayerFloating.withDefault(true))
                    .onChange(of: preferences.miniPlayerFloating) { save() }
                Text("Whether the mini player should float or be fixed at the bottom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
//            if !(preferences.isPremiumUser ?? false) {
//                Section {
//                    Button("Unlock Premium Themes") {
//                        preferences.isPremiumUser = true // Simulation
//                        save()
//                    }
//                }
//            }
        }
        .navigationTitle("Appearance")
        .scrollContentBackground(.hidden)
        .listRowBackground(theme.secondaryBackground)
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            updateColorsFromPreferences()
        }
    }
    
    private var currentAccentColor: Color {
        if let hex = preferences.customAccentColorHex, let color = Color(hex: hex) {
            return color
        }
        return preferences.selectedTheme.accentColor() ?? .accentColor
    }
    
    private func updateColorsFromPreferences() {
        if let hex = preferences.customAccentColorHex, let color = Color(hex: hex) {
            accentColor = color
        } else {
            accentColor = preferences.selectedTheme.accentColor() ?? Color("AccentColor")
        }
        
        if let hex = preferences.customBackgroundColorHex, let color = Color(hex: hex) {
            backgroundColor = color
        } else {
            backgroundColor = .black
        }
    }
    
    private func save() {
        print("[DEBUG] Saving preferences: selectedTheme=\(preferences.selectedTheme.rawValue)")
        try? modelContext.save()
    }
}

