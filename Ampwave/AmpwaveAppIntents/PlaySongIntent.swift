//
//  PlaySongIntent.swift
//  Ampwave
//
//  Siri intent for song-first playback in Ampwave.
//

import AppIntents
import Foundation

@available(iOS 17.0, macOS 14.0, *)
public struct SiriSongReferenceQuery: EntityStringQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [SiriSongReference] {
    identifiers.map { SiriSongReference(id: $0, name: $0) }
  }

  public func entities(matching string: String) async throws -> [SiriSongReference] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let libraryMatches = await MainActor.run {
      SongLibrary.shared.songs
        .filter {
          $0.title.localizedCaseInsensitiveContains(trimmed)
            || $0.artist.localizedCaseInsensitiveContains(trimmed)
        }
        .prefix(5)
        .map { SiriSongReference(id: $0.title, name: $0.title) }
    }

    if libraryMatches.isEmpty {
      return [SiriSongReference(id: trimmed, name: trimmed)]
    }

    return Array(libraryMatches)
  }

  public func suggestedEntities() async throws -> [SiriSongReference] {
    await MainActor.run {
      Array(
        SongLibrary.shared.songs
          .prefix(10)
          .map { SiriSongReference(id: $0.title, name: $0.title) }
      )
    }
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct SiriSongReference: AppEntity {
  public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
  public static var defaultQuery = SiriSongReferenceQuery()

  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlaySongIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Song"
  public static var description = IntentDescription(
    "Searches Apple Music first, falls back to your Ampwave library, and starts playback."
  )
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Song")
  public var song: SiriSongReference

  @Parameter(title: "Artist")
  public var artist: String?

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$song) in Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    _ = try await SiriPlaybackRouter.shared.playSong(songTitle: song.name, artistName: artist)
    return .result()
  }
}
