//
//  GenrePalette.swift
//  Ampwave
//

internal import SwiftUI

enum GenrePalette {

  // MARK: - Genre icon

  static func icon(for name: String) -> String {
    let l = name.lowercased()
    if l.contains("rock") || l.contains("punk") { return "guitars.fill" }
    if l.contains("metal") { return "guitars.fill" }
    if l.contains("jazz") { return "music.quarternote.3" }
    if l.contains("classical") || l.contains("orchestra") || l.contains("opera") {
      return "pianokeys.inverse"
    }
    if l.contains("electronic") || l.contains("edm") || l.contains("techno")
      || l.contains("house") || l.contains("trance")
    {
      return "waveform"
    }
    if l.contains("hip hop") || l.contains("hip-hop") || l.contains("rap") || l.contains("trap") {
      return "music.mic"
    }
    if l.contains("r&b") || l.contains("soul") || l.contains("funk") { return "heart.fill" }
    if l.contains("pop") { return "sparkles" }
    if l.contains("country") || l.contains("bluegrass") { return "guitars" }
    if l.contains("reggae") || l.contains("ska") { return "leaf.fill" }
    if l.contains("latin") || l.contains("salsa") || l.contains("cumbia") {
      return "music.note.list"
    }
    if l.contains("folk") || l.contains("acoustic") { return "guitars" }
    if l.contains("blues") { return "moon.fill" }
    if l.contains("indie") { return "star.fill" }
    if l.contains("alternative") || l.contains("alt") { return "waveform.and.mic" }
    if l.contains("k-pop") || l.contains("kpop") || l.contains("j-pop") { return "sparkles" }
    if l.contains("gospel") || l.contains("christian") || l.contains("worship") {
      return "music.note.list"
    }
    if l.contains("ambient") || l.contains("lo-fi") || l.contains("chill") { return "cloud.fill" }
    if l.contains("dance") { return "waveform" }
    return "music.note"
  }

  // MARK: - Gradient colors

  static func gradient(for name: String) -> [Color] {
    let l = name.lowercased()

    if l.contains("pop") && !l.contains("hip") && !l.contains("k-pop") && !l.contains("j-pop") {
      return [Color(red: 0.98, green: 0.22, blue: 0.60), Color(red: 0.58, green: 0.10, blue: 0.88)]
    }
    if l.contains("rock") && !l.contains("indie") && !l.contains("alt") {
      return [Color(red: 0.92, green: 0.18, blue: 0.18), Color(red: 0.45, green: 0.04, blue: 0.04)]
    }
    if l.contains("hip hop") || l.contains("hip-hop") || l.contains("rap") || l.contains("trap") {
      return [Color(red: 0.96, green: 0.68, blue: 0.04), Color(red: 0.88, green: 0.30, blue: 0.04)]
    }
    if l.contains("electronic") || l.contains("edm") || l.contains("techno")
      || l.contains("house") || l.contains("trance")
    {
      return [Color(red: 0.04, green: 0.74, blue: 0.96), Color(red: 0.04, green: 0.14, blue: 0.88)]
    }
    if l.contains("dance") {
      return [Color(red: 0.04, green: 0.60, blue: 0.96), Color(red: 0.50, green: 0.04, blue: 0.88)]
    }
    if l.contains("r&b") || l.contains("soul") || l.contains("funk") {
      return [Color(red: 0.62, green: 0.08, blue: 0.92), Color(red: 0.96, green: 0.22, blue: 0.52)]
    }
    if l.contains("jazz") {
      return [Color(red: 0.04, green: 0.28, blue: 0.72), Color(red: 0.36, green: 0.64, blue: 0.92)]
    }
    if l.contains("classical") || l.contains("orchestra") || l.contains("opera") {
      return [Color(red: 0.72, green: 0.54, blue: 0.18), Color(red: 0.44, green: 0.28, blue: 0.04)]
    }
    if l.contains("country") || l.contains("bluegrass") {
      return [Color(red: 0.88, green: 0.56, blue: 0.04), Color(red: 0.56, green: 0.24, blue: 0.04)]
    }
    if l.contains("metal") || l.contains("punk") {
      return [Color(red: 0.22, green: 0.22, blue: 0.28), Color(red: 0.04, green: 0.04, blue: 0.10)]
    }
    if l.contains("reggae") || l.contains("ska") {
      return [Color(red: 0.08, green: 0.68, blue: 0.28), Color(red: 0.92, green: 0.72, blue: 0.04)]
    }
    if l.contains("latin") || l.contains("salsa") {
      return [Color(red: 0.96, green: 0.38, blue: 0.04), Color(red: 0.88, green: 0.10, blue: 0.30)]
    }
    if l.contains("folk") || l.contains("acoustic") {
      return [Color(red: 0.52, green: 0.70, blue: 0.28), Color(red: 0.28, green: 0.44, blue: 0.08)]
    }
    if l.contains("blues") {
      return [Color(red: 0.08, green: 0.22, blue: 0.72), Color(red: 0.04, green: 0.52, blue: 0.88)]
    }
    if l.contains("indie") {
      return [Color(red: 0.88, green: 0.44, blue: 0.78), Color(red: 0.42, green: 0.14, blue: 0.68)]
    }
    if l.contains("alternative") || l.contains("alt-rock") {
      return [Color(red: 0.28, green: 0.82, blue: 0.62), Color(red: 0.04, green: 0.42, blue: 0.36)]
    }
    if l.contains("k-pop") || l.contains("kpop") || l.contains("j-pop") {
      return [Color(red: 0.96, green: 0.28, blue: 0.62), Color(red: 0.42, green: 0.08, blue: 0.92)]
    }
    if l.contains("gospel") || l.contains("christian") || l.contains("worship") {
      return [Color(red: 0.96, green: 0.82, blue: 0.28), Color(red: 0.72, green: 0.42, blue: 0.04)]
    }
    if l.contains("ambient") || l.contains("lo-fi") || l.contains("chill") {
      return [Color(red: 0.28, green: 0.48, blue: 0.72), Color(red: 0.04, green: 0.20, blue: 0.44)]
    }

    // Stable hash fallback — consistent across app launches (String.hashValue is NOT stable)
    let idx = abs(stableHash(name)) % vibrantFallback.count
    return vibrantFallback[idx]
  }

  // MARK: - Private

  private static let vibrantFallback: [[Color]] = [
    [Color(red: 0.98, green: 0.22, blue: 0.60), Color(red: 0.58, green: 0.10, blue: 0.88)],
    [Color(red: 0.04, green: 0.74, blue: 0.96), Color(red: 0.04, green: 0.14, blue: 0.88)],
    [Color(red: 0.96, green: 0.46, blue: 0.04), Color(red: 0.88, green: 0.10, blue: 0.34)],
    [Color(red: 0.04, green: 0.82, blue: 0.46), Color(red: 0.04, green: 0.46, blue: 0.30)],
    [Color(red: 0.64, green: 0.08, blue: 0.92), Color(red: 0.96, green: 0.22, blue: 0.54)],
    [Color(red: 0.96, green: 0.76, blue: 0.04), Color(red: 0.92, green: 0.36, blue: 0.04)],
    [Color(red: 0.04, green: 0.34, blue: 0.88), Color(red: 0.34, green: 0.64, blue: 0.96)],
    [Color(red: 0.82, green: 0.14, blue: 0.18), Color(red: 0.48, green: 0.04, blue: 0.04)],
    [Color(red: 0.28, green: 0.82, blue: 0.62), Color(red: 0.04, green: 0.42, blue: 0.36)],
    [Color(red: 0.88, green: 0.44, blue: 0.78), Color(red: 0.42, green: 0.14, blue: 0.68)],
  ]

  /// DJB2 hash — stable across app launches (unlike String.hashValue which is randomised per session)
  private static func stableHash(_ str: String) -> Int {
    str.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
  }
}
