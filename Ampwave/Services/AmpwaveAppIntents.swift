//
//  AmpwaveAppIntents.swift
//  Ampwave
//

import AppIntents
import Foundation

#if canImport(UIKit)
  import UIKit
#endif
#if os(macOS)
  import AppKit
#endif

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
  public static var openAppWhenRun: Bool = true

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlayLikedSongsIntent.perform")
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
  public static var openAppWhenRun: Bool = true

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: ResumePlaybackIntent.perform")
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
    public static var caseDisplayRepresentations: [PlaybackAction: DisplayRepresentation] = [
      .play: "Play",
      .pause: "Pause",
      .toggle: "Toggle Play/Pause",
      .next: "Next Track",
      .previous: "Previous Track",
    ]
  }

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: ControlPlaybackIntent.perform (action: \(action.rawValue))")
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
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Query", description: "The song, artist, album, or playlist to play")
  public var query: String

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$query) on Ampwave")
  }

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlayMusicIntent.perform (query: \(query))")
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
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Artist Name")
  public var artistName: String

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlayArtistIntent.perform (artist: \(artistName))")
    let results = await SearchManager.shared.search(query: artistName, filter: .artists)

    await MainActor.run {
      if let artist = results.artists.first {
        PlaybackController.shared.playArtist(artist.name)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PlaySpecificPlaylistIntent: AudioPlaybackIntent {
  public static var title: LocalizedStringResource = "Play Playlist"
  public static var description = IntentDescription("Plays a specific playlist in Ampwave.")
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Playlist Name")
  public var playlistName: String

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: PlaySpecificPlaylistIntent.perform (playlist: \(playlistName))")
    let results = await SearchManager.shared.search(query: playlistName, filter: .playlists)

    await MainActor.run {
      if let playlist = results.playlists.first {
        PlaybackController.shared.playPlaylist(playlist)
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
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Playlist Name")
  public var playlistName: String

  public init() {}

  public func perform() async throws -> some IntentResult {
    print("[DEBUG] Siri: AddToPlaylistIntent.perform (playlist: \(playlistName))")
    let results = await SearchManager.shared.search(query: playlistName, filter: .playlists)

    await MainActor.run {
      if let playlist = results.playlists.first,
        let song = PlaybackController.shared.currentItem
      {
        PlaylistManager.shared.addSong(song, to: playlist)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct AmpwaveShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    // ── Song-specific (entity parameter — allowed in phrases) ────────────────
    AppShortcut(
      intent: PlaySongIntent(),
      phrases: [
        "Play \(\.$song) on \(.applicationName)",
        "Play \(\.$song) in \(.applicationName)",
        "Play the song \(\.$song) on \(.applicationName)",
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

    // ── Artist — String param, Siri prompts ──────────────────────────────────
    AppShortcut(
      intent: PlayArtistIntent(),
      phrases: [
        "Play an artist on \(.applicationName)",
        "Play artist music on \(.applicationName)",
      ],
      shortTitle: "Play Artist",
      systemImageName: "music.mic"
    )

    // ── Playlist — String param, Siri prompts ────────────────────────────────
    AppShortcut(
      intent: PlaySpecificPlaylistIntent(),
      phrases: [
        "Play a playlist on \(.applicationName)",
        "Start a playlist on \(.applicationName)",
        "Play my playlist on \(.applicationName)",
      ],
      shortTitle: "Play Playlist",
      systemImageName: "music.note.list"
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
        "Add this song to a playlist on \(.applicationName)",
        "Add to playlist on \(.applicationName)",
      ],
      shortTitle: "Add to Playlist",
      systemImageName: "plus.circle"
    )
  }
}
