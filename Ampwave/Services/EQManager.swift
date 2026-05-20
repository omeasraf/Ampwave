//
//  EQManager.swift
//  Ampwave
//

import Foundation
internal import SwiftUI

// MARK: - EQ Preset Model

struct EQPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var gains: [Float]  // 10 values, -12 to +12 dB
    var isBuiltIn: Bool

    static func == (lhs: EQPreset, rhs: EQPreset) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Built-in Presets

extension EQPreset {
    static let bandCount = 10

    static let flat = EQPreset(id: UUID(), name: "Flat", gains: Array(repeating: 0, count: 10), isBuiltIn: true)

    static let builtIn: [EQPreset] = [
        flat,
        EQPreset(id: UUID(), name: "Bass Boost",     gains: [7, 5, 4, 2, 1, 0, 0, 0, 0, 0],      isBuiltIn: true),
        EQPreset(id: UUID(), name: "Treble Boost",   gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],      isBuiltIn: true),
        EQPreset(id: UUID(), name: "Vocal Enhance",  gains: [-2, -1, 0, 1, 3, 4, 4, 2, 1, 0],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Rock",           gains: [5, 4, 2, -1, -2, -1, 2, 3, 4, 3],   isBuiltIn: true),
        EQPreset(id: UUID(), name: "Pop",            gains: [-1, 1, 2, 3, 4, 4, 3, 2, 0, -1],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Jazz",           gains: [4, 3, 2, 2, -1, -1, 1, 2, 3, 4],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Classical",      gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Electronic",     gains: [5, 3, 0, -2, -2, 0, 2, 2, 3, 4],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Acoustic",       gains: [4, 3, 3, 3, 3, 2, 2, 2, 3, 2],      isBuiltIn: true),
        EQPreset(id: UUID(), name: "Hip-Hop",        gains: [6, 5, 3, 2, -1, -1, 0, 2, 3, 2],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Dance",          gains: [4, 3, 2, -1, -2, -1, 2, 3, 4, 3],   isBuiltIn: true),
        EQPreset(id: UUID(), name: "Deep Bass",      gains: [8, 7, 5, 2, 0, -1, -1, 0, 0, 0],    isBuiltIn: true),
        EQPreset(id: UUID(), name: "Warm",           gains: [4, 4, 3, 2, 1, 0, -1, -1, -2, -2],  isBuiltIn: true),
        EQPreset(id: UUID(), name: "Soundstage",     gains: [2, 1, 0, -1, -1, -1, 0, 1, 3, 6],   isBuiltIn: true),
    ]
}

// MARK: - EQ Manager

@Observable
final class EQManager {
    static let shared = EQManager()

    // The 10 standard EQ center frequencies (Hz)
    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels: [String] = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    /// True while `loadFromDefaults()` is running — prevents `persist()` from
    /// overwriting stored values with in-progress defaults during init.
    private var isLoading = false

    var isEnabled: Bool = false {
        didSet {
            VocalIsolator.shared.setEQEnabled(isEnabled)
            persist()
        }
    }

    var bands: [Float] = Array(repeating: 0, count: 10) {
        didSet {
            for (i, gain) in bands.enumerated() {
                VocalIsolator.shared.setEQGain(gain, atBand: i)
            }
        }
    }

    var currentPresetName: String = "Flat"
    var userPresets: [EQPreset] = []

    var allPresets: [EQPreset] {
        EQPreset.builtIn + userPresets
    }

    private init() {
        loadFromDefaults()
        syncToVocalIsolator()
    }

    func applyPreset(_ preset: EQPreset) {
        currentPresetName = preset.name
        bands = preset.gains
        for (i, gain) in preset.gains.enumerated() {
            VocalIsolator.shared.setEQGain(gain, atBand: i)
        }
        persist()
    }

    func applyFlat() {
        currentPresetName = "Flat"
        bands = Array(repeating: 0, count: 10)
        for i in 0..<10 {
            VocalIsolator.shared.setEQGain(0, atBand: i)
        }
        persist()
    }

    func saveUserPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Remove existing user preset with same name
        userPresets.removeAll { $0.name == trimmed }
        let preset = EQPreset(id: UUID(), name: trimmed, gains: bands, isBuiltIn: false)
        userPresets.append(preset)
        currentPresetName = trimmed
        persist()
    }

    func deleteUserPreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.id == preset.id }
        persist()
    }

    // MARK: - Persistence

    private func syncToVocalIsolator() {
        VocalIsolator.shared.setEQEnabled(isEnabled)
        for (i, gain) in bands.enumerated() {
            VocalIsolator.shared.setEQGain(gain, atBand: i)
        }
    }

    func persist() {
        guard !isLoading else { return }
        UserDefaults.standard.set(isEnabled, forKey: "com.ampwave.eqEnabled")
        UserDefaults.standard.set(currentPresetName, forKey: "com.ampwave.eqPresetName")
        if let data = try? JSONEncoder().encode(bands) {
            UserDefaults.standard.set(data, forKey: "com.ampwave.eqBands")
        }
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(data, forKey: "com.ampwave.eqUserPresets")
        }
    }

    func loadFromDefaults() {
        isLoading = true
        defer { isLoading = false }

        isEnabled = UserDefaults.standard.bool(forKey: "com.ampwave.eqEnabled")
        currentPresetName = UserDefaults.standard.string(forKey: "com.ampwave.eqPresetName") ?? "Flat"

        if let data = UserDefaults.standard.data(forKey: "com.ampwave.eqBands"),
           let decoded = try? JSONDecoder().decode([Float].self, from: data),
           decoded.count == 10
        {
            bands = decoded
        }

        if let data = UserDefaults.standard.data(forKey: "com.ampwave.eqUserPresets"),
           let decoded = try? JSONDecoder().decode([EQPreset].self, from: data)
        {
            userPresets = decoded
        }
    }
}
