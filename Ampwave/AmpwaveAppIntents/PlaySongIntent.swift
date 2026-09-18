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
  // Native voice playback is handled by INPlayMediaIntent. Keeping this
  // action hidden prevents Siri from treating it as a two-step shortcut.
  public static var isDiscoverable: Bool = false
  // AudioPlaybackIntent exists so playback can start without foregrounding the
  // app — forcing it open also made this fail from a locked screen.
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Song", requestValueDialog: IntentDialog("What song would you like to play?"))
  var song: SongEntity

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$song) in Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    await SiriIntentEnvironment.prepareLibrary(includePlayback: true)
    let title = song.title
    let artist = song.artist
    _ = try await SiriPlaybackRouter.shared.playSong(songTitle: title, artistName: artist)
    return .result()
  }
}
