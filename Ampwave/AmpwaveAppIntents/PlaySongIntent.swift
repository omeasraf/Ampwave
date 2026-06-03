//
//  PlaySongIntent.swift
//  Ampwave
//
//  Siri intent for song-first playback in Ampwave.
//

import AppIntents
import Foundation

@available(iOS 17.0, macOS 14.0, *)
public struct PlaySongIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Song"
  public static var description = IntentDescription(
    "Searches your music library and starts playback in Ampwave."
  )
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Song", requestValueDialog: IntentDialog("What song would you like to play?"))
  public var song: String

  @Parameter(title: "Artist")
  public var artist: String?

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$song) in Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    _ = try await SiriPlaybackRouter.shared.playSong(songTitle: song, artistName: artist)
    return .result()
  }
}
