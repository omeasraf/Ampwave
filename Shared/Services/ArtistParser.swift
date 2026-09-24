//
//  ArtistParser.swift
//  Ampwave
//
//  Parses artist strings and splits multiple artists by common delimiters.
//

import Foundation

enum ArtistParser {
  // Semicolons are the most reliable separator used by tag editors. Treat
  // spaced ampersands and feature markers as separators too, but do not
  // split on commas or "and": both occur inside real artist names.
  nonisolated private static let separator = try! NSRegularExpression(
    pattern: #"\s*;\s*|\s+&\s+|\s+(?:feat\.?|ft\.?|featuring)\s+"#,
    options: [.caseInsensitive]
  )

  /// Parse artist string and split into individual artists
  /// - Parameter artistString: The raw artist string (e.g., "Gracie Abrams; Taylor Swift")
  /// - Returns: Array of trimmed artist names
  nonisolated static func parseArtists(from artistString: String) -> [String] {
    let range = NSRange(artistString.startIndex..<artistString.endIndex, in: artistString)
    let separated = separator.stringByReplacingMatches(
      in: artistString, range: range, withTemplate: "\u{001F}"
    )
    return separated.split(separator: "\u{001F}")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Some older imports stored a combined credit as a *single item* in the
  /// artists array. Flatten and deduplicate it without changing the displayed
  /// credit string on the song.
  nonisolated static func normalizedArtists(_ credited: [String], fallback: String) -> [String] {
    let raw = credited.isEmpty ? [fallback] : credited
    var seen = Set<String>()
    let result = raw.flatMap(parseArtists).filter {
      seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        .inserted
    }
    return result.isEmpty ? parseArtists(from: fallback) : result
  }

  /// Join multiple artists into a display string
  /// - Parameter artists: Array of artist names
  /// - Returns: Formatted string for display
  nonisolated static func formatArtists(_ artists: [String]) -> String {
    guard !artists.isEmpty else { return "Unknown Artist" }

    switch artists.count {
    case 0:
      return "Unknown Artist"
    case 1:
      return artists[0]
    case 2:
      return "\(artists[0]) & \(artists[1])"
    default:
      let first = artists[0]
      let rest = artists.dropFirst().joined(separator: ", ")
      return "\(first) & \(rest)"
    }
  }
}
