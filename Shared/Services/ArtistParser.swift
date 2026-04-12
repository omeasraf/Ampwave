//
//  ArtistParser.swift
//  Ampwave
//
//  Parses artist strings and splits multiple artists by common delimiters.
//

import Foundation

enum ArtistParser {
  /// Common delimiters for separating multiple artists
  private static let delimiters = [
    ", ",  // Common comma separator
    "; ",  // Semicolon separator
    " & ",  // Ampersand with spaces
    "&",  // Ampersand without spaces
    " feat. ",  // Featuring
    " Feat. ",
    " ft. ",  // Ft.
    " Ft. ",
    " featuring ",  // Full word
    " Featuring ",
  ]

  /// Parse artist string and split into individual artists
  /// - Parameter artistString: The raw artist string (e.g., "Gracie Abrams; Taylor Swift")
  /// - Returns: Array of trimmed artist names
  static func parseArtists(from artistString: String) -> [String] {
    guard !artistString.isEmpty else { return [] }

    var remaining = artistString
    var artists: [String] = []

    // Try to split by each delimiter in order of preference
    for delimiter in delimiters {
      if remaining.contains(delimiter) {
        artists =
          remaining
          .split(separator: delimiter, omittingEmptySubsequences: true)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }

        // If we found a split, stop here
        if artists.count > 1 {
          return artists
        }
      }
    }

    // No delimiter found, return single artist
    let trimmed = artistString.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? [] : [trimmed]
  }

  /// Join multiple artists into a display string
  /// - Parameter artists: Array of artist names
  /// - Returns: Formatted string for display
  static func formatArtists(_ artists: [String]) -> String {
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
