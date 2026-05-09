//
//  GenrePalette.swift
//  Ampwave
//

internal import SwiftUI

enum GenrePalette {
  static func gradient(for name: String) -> [Color] {
    let presets: [[Color]] = [
      [Color(red: 0.45, green: 0.2, blue: 0.85), Color(red: 0.95, green: 0.35, blue: 0.55)],
      [Color(red: 0.1, green: 0.45, blue: 0.95), Color(red: 0.2, green: 0.85, blue: 0.9)],
      [Color(red: 0.95, green: 0.45, blue: 0.15), Color(red: 0.9, green: 0.2, blue: 0.35)],
      [Color(red: 0.15, green: 0.65, blue: 0.35), Color(red: 0.35, green: 0.85, blue: 0.5)],
      [Color(red: 0.35, green: 0.25, blue: 0.75), Color(red: 0.55, green: 0.4, blue: 0.95)],
      [Color(red: 0.2, green: 0.25, blue: 0.35), Color(red: 0.45, green: 0.5, blue: 0.65)],
    ]
    let idx = abs(name.hashValue) % presets.count
    return presets[idx]
  }
}
