//
//  AmpwaveAppIntents.swift
//  Ampwave
//

import AppIntents
import Foundation
import SwiftData

#if canImport(UIKit)
  import UIKit
#endif
#if os(macOS)
  import AppKit
#endif

/// App Intents can be launched while Ampwave's UI has never appeared. In that
/// case ContentView has not attached the SwiftData context or loaded the
/// singleton libraries yet, so every Siri entity query used to return an empty
/// result. The app configures this bridge at process launch and intents prepare
/// only the services they need.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
enum SiriIntentEnvironment {
  private static var modelContext: ModelContext?
  private static var libraryPrepared = false
  private static var playlistsPrepared = false
  private static var playbackPrepared = false

  static func configure(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  static func prepareLibrary(includePlaylists: Bool = false, includePlayback: Bool = false) async {
    guard let modelContext else {
      DiagnosticLog.shared.log("siri", "Intent environment has no model context")
      return
    }

    if !libraryPrepared {
      libraryPrepared = true
      SongLibrary.shared.modelContext = modelContext
      await SongLibrary.shared.loadSongs(performMaintenance: false)
      DiagnosticLog.shared.log(
        "siri", "Cold-launch library prepared songs=\(SongLibrary.shared.songs.count)")
    }

    if includePlaylists && !playlistsPrepared {
      playlistsPrepared = true
      PlaylistManager.shared.modelContext = modelContext
      await PlaylistManager.shared.loadPlaylists()
    }

    if includePlayback && !playbackPrepared {
      playbackPrepared = true
      PlaybackController.shared.setModelContext(modelContext)
      PlaybackController.shared.restoreStateAfterLoading()
    }
  }
}

@available(iOS 17.0, macOS 14.0, *)
enum AmpwaveShortcutURLs {
  static let scheme = "ampwave"
  static func open(_ path: String) -> URL {
    URL(string: "\(scheme)://\(path)")!
  }

  static func openInApp(_ path: String) {
    let url = open(path)
    #if os(iOS)
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    #elseif os(macOS)
      NSWorkspace.shared.open(url)
    #endif
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlayLikedSongsIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Liked Songs"
  public static var description = IntentDescription(
    "Starts playback of your Liked Songs playlist in Ampwave.")
  public static var openAppWhenRun: Bool = false

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlayLikedSongsIntent.perform")
    await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)
    await MainActor.run {
      let pm = PlaylistManager.shared
      let playback = PlaybackController.shared
      if let liked = pm.likedSongsPlaylist, !liked.songs.isEmpty {
        playback.playPlaylist(liked)
      } else {
        print("[DEBUG] Siri: No liked songs found, opening app")
        AmpwaveShortcutURLs.openInApp("play/liked")
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct ResumePlaybackIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Resume Ampwave"
  public static var description = IntentDescription(
    "Opens Ampwave and resumes the last queue if possible.")
  public static var openAppWhenRun: Bool = false

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: ResumePlaybackIntent.perform")
    await SiriIntentEnvironment.prepareLibrary(includePlayback: true)
    await MainActor.run {
      let playback = PlaybackController.shared
      if playback.currentItem != nil {
        playback.play()
      } else {
        playback.restoreStateAfterLoading()
        playback.play()
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct ControlPlaybackIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Control Playback"
  public static var description = IntentDescription("Controls music playback in Ampwave.")

  @Parameter(title: "Action")
  public var action: PlaybackAction

  public enum PlaybackAction: String, AppEnum {
    case play, pause, toggle, next, previous

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playback Action"
    // These titles are spoken back and matched against, so they read as the
    // words someone would actually say.
    public static var caseDisplayRepresentations: [PlaybackAction: DisplayRepresentation] = [
      .play: "Play",
      .pause: "Pause",
      .toggle: "Play or pause",
      .next: "Skip",
      .previous: "Go back",
    ]
  }

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: ControlPlaybackIntent.perform (action: \(action.rawValue))")
    await SiriIntentEnvironment.prepareLibrary(includePlayback: true)
    await MainActor.run {
      let playback = PlaybackController.shared
      switch action {
      case .play: playback.play()
      case .pause: playback.pause()
      case .toggle: playback.playPause()
      case .next: playback.playNext()
      case .previous: playback.playPrevious()
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct LikeCurrentSongIntent: AppIntent {
  public static var title: LocalizedStringResource = "Like This Song"
  public static var description = IntentDescription(
    "Likes or unlikes the currently playing song in Ampwave.")

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: LikeCurrentSongIntent.perform")
    await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)
    await MainActor.run {
      if let song = PlaybackController.shared.currentItem {
        _ = PlaylistManager.shared.toggleLike(song: song)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlayMusicIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Music"
  public static var description = IntentDescription(
    "Plays music in Ampwave based on a search query.")
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Query", description: "The song, artist, album, or playlist to play")
  public var query: String

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$query) on Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlayMusicIntent.perform (query: \(query))")
    await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)
    if let songResult = try? await SiriPlaybackRouter.shared.playSong(songTitle: query) {
      print("[DEBUG] Siri: Routed query through SiriPlaybackRouter (\(songResult.source.rawValue))")
      return .result()
    }

    let results = await SearchManager.shared.search(query: query, filter: .all)

    await MainActor.run {
      let playback = PlaybackController.shared

      if let song = results.topSong {
        print("[DEBUG] Siri: Playing song \(song.title)")
        playback.play(song, from: .library)
      } else if let artist = results.artists.first {
        print("[DEBUG] Siri: Playing artist \(artist.name)")
        playback.playArtist(artist.name)
      } else if let album = results.albums.first {
        print("[DEBUG] Siri: Playing album \(album.name)")
        playback.playAlbum(album)
      } else if let playlist = results.playlists.first {
        print("[DEBUG] Siri: Playing playlist \(playlist.name)")
        playback.playPlaylist(playlist)
      } else {
        print("[DEBUG] Siri: No results found for query")
      }
    }

    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlayArtistIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Artist"
  public static var description = IntentDescription("Plays songs by a specific artist in Ampwave.")
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Artist", requestValueDialog: IntentDialog("Which artist?"))
  var artist: ArtistEntity

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$artist) in Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    let name = artist.name
    print("[DEBUG] Siri: PlayArtistIntent.perform (artist: \(name))")
    await SiriIntentEnvironment.prepareLibrary(includePlayback: true)
    await MainActor.run {
      PlaybackController.shared.playArtist(name)
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlaySpecificPlaylistIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Playlist"
  public static var description = IntentDescription("Plays a specific playlist in Ampwave.")
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Playlist", requestValueDialog: IntentDialog("Which playlist?"))
  var playlist: PlaylistEntity

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$playlist) in Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    let id = playlist.id
    print("[DEBUG] Siri: PlaySpecificPlaylistIntent.perform (playlist: \(playlist.name))")
    await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)
    await MainActor.run {
      if let match = PlaylistManager.shared.playlists.first(where: { $0.id == id }) {
        PlaybackController.shared.playPlaylist(match)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct AddToPlaylistIntent: AppIntent {
  public static var title: LocalizedStringResource = "Add to Playlist"
  public static var description = IntentDescription(
    "Adds the currently playing song to a playlist.")
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Playlist", requestValueDialog: IntentDialog("Which playlist?"))
  var playlist: PlaylistEntity

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Add the current song to \(\.$playlist)")
  }

  public func perform() async throws -> some IntentResult {
    let id = playlist.id
    print("[DEBUG] Siri: AddToPlaylistIntent.perform (playlist: \(playlist.name))")
    await SiriIntentEnvironment.prepareLibrary(includePlaylists: true, includePlayback: true)
    await MainActor.run {
      if let match = PlaylistManager.shared.playlists.first(where: { $0.id == id }),
        let song = PlaybackController.shared.currentItem
      {
        PlaylistManager.shared.addSong(song, to: match)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct AmpwaveShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    // The content parameter is interpolated directly into the phrase, so
    // "Play <title> on Ampwave" is understood in one shot. That only works
    // because these are AppEntity parameters — Siri refuses to slot a String
    // into a phrase, which is why these used to read "Play a song on Ampwave"
    // and anything more natural fell through to the system media handler.
    AppShortcut(
      intent: PlaySongIntent(),
      phrases: [
        "Play \(\.$song) on \(.applicationName)",
        "Play \(\.$song) in \(.applicationName)",
        "Play the song \(\.$song) on \(.applicationName)",
        "Play a song on \(.applicationName)",
      ],
      shortTitle: "Play Song",
      systemImageName: "music.note"
    )

    // ── Generic search — String param, so Siri prompts for it ────────────────
    AppShortcut(
      intent: PlayMusicIntent(),
      phrases: [
        "Play music on \(.applicationName)",
        "Play something on \(.applicationName)",
        "Search and play on \(.applicationName)",
      ],
      shortTitle: "Play Music",
      systemImageName: "magnifyingglass"
    )

    AppShortcut(
      intent: PlayArtistIntent(),
      phrases: [
        "Play \(\.$artist) on \(.applicationName)",
        "Play music by \(\.$artist) on \(.applicationName)",
        "Play songs by \(\.$artist) on \(.applicationName)",
        "Play an artist on \(.applicationName)",
      ],
      shortTitle: "Play Artist",
      systemImageName: "music.mic"
    )

    AppShortcut(
      intent: PlaySpecificPlaylistIntent(),
      phrases: [
        "Play \(\.$playlist) on \(.applicationName)",
        "Play my \(\.$playlist) playlist on \(.applicationName)",
        "Start \(\.$playlist) on \(.applicationName)",
        "Play a playlist on \(.applicationName)",
      ],
      shortTitle: "Play Playlist",
      systemImageName: "music.note.list"
    )

    // ── Transport controls — previously unreachable by voice at all ──────────
    AppShortcut(
      intent: ControlPlaybackIntent(),
      phrases: [
        "\(\.$action) on \(.applicationName)",
        "\(\.$action) in \(.applicationName)",
        "\(\.$action) music on \(.applicationName)",
      ],
      shortTitle: "Control Playback",
      systemImageName: "playpause"
    )

    // ── Liked songs ──────────────────────────────────────────────────────────
    AppShortcut(
      intent: PlayLikedSongsIntent(),
      phrases: [
        "Play liked songs on \(.applicationName)",
        "Play my favorites on \(.applicationName)",
        "Play favorites on \(.applicationName)",
      ],
      shortTitle: "Play Liked",
      systemImageName: "heart.fill"
    )

    // ── Resume ───────────────────────────────────────────────────────────────
    AppShortcut(
      intent: ResumePlaybackIntent(),
      phrases: [
        "Resume \(.applicationName)",
        "Continue playing on \(.applicationName)",
        "Resume music on \(.applicationName)",
      ],
      shortTitle: "Resume",
      systemImageName: "play.fill"
    )

    // ── Like current song ────────────────────────────────────────────────────
    AppShortcut(
      intent: LikeCurrentSongIntent(),
      phrases: [
        "Like this song on \(.applicationName)",
        "Favorite this song on \(.applicationName)",
      ],
      shortTitle: "Like Song",
      systemImageName: "heart"
    )

    // ── Add to playlist ──────────────────────────────────────────────────────
    AppShortcut(
      intent: AddToPlaylistIntent(),
      phrases: [
        "Add this song to \(\.$playlist) on \(.applicationName)",
        "Add this to \(\.$playlist) on \(.applicationName)",
        "Add this song to a playlist on \(.applicationName)",
      ],
      shortTitle: "Add to Playlist",
      systemImageName: "plus.circle"
    )
  }
}
