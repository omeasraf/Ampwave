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
struct PlayLikedSongsIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Liked Songs"
  static var description = IntentDescription(
    "Starts playback of your Liked Songs playlist in Ampwave.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      let pm = PlaylistManager.shared
      let playback = PlaybackController.shared
      if let liked = pm.likedSongsPlaylist, !liked.songs.isEmpty {
        playback.playPlaylist(liked)
      } else {
        AmpwaveShortcutURLs.openInApp("play/liked")
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct ResumePlaybackIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Resume Ampwave"
  static var description = IntentDescription(
    "Opens Ampwave and resumes the last queue if possible.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
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
struct ControlPlaybackIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Control Playback"
  static var description = IntentDescription("Controls music playback in Ampwave.")
  
  @Parameter(title: "Action")
  var action: PlaybackAction
  
  enum PlaybackAction: String, AppEnum {
    case play, pause, toggle, next, previous
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playback Action"
    static var caseDisplayRepresentations: [PlaybackAction: DisplayRepresentation] = [
      .play: "Play",
      .pause: "Pause",
      .toggle: "Toggle Play/Pause",
      .next: "Next Track",
      .previous: "Previous Track"
    ]
  }

  func perform() async throws -> some IntentResult {
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
struct LikeCurrentSongIntent: AppIntent {
  static var title: LocalizedStringResource = "Like This Song"
  static var description = IntentDescription("Likes or unlikes the currently playing song in Ampwave.")

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      if let song = PlaybackController.shared.currentItem {
        _ = PlaylistManager.shared.toggleLike(song: song)
      }
    }
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct PlayMusicIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Music"
  static var description = IntentDescription("Plays music in Ampwave based on a search query.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Query", description: "The song, artist, album, or playlist to play")
  var query: String

  func perform() async throws -> some IntentResult {
    let results = await SearchManager.shared.search(query: query, filter: .all)
    
    await MainActor.run {
      let playback = PlaybackController.shared
      
      if let song = results.topSong {
        playback.play(song, from: .library)
      } else if let artist = results.artists.first {
        playback.playArtist(artist.name)
      } else if let album = results.albums.first {
        playback.playAlbum(album)
      } else if let playlist = results.playlists.first {
        playback.playPlaylist(playlist)
      }
    }
    
    return .result()
  }
}

@available(iOS 17.0, macOS 14.0, *)
struct PlayArtistIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Artist"
  static var description = IntentDescription("Plays songs by a specific artist in Ampwave.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Artist Name")
  var artistName: String

  func perform() async throws -> some IntentResult {
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
struct PlaySpecificPlaylistIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Playlist"
  static var description = IntentDescription("Plays a specific playlist in Ampwave.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Playlist Name")
  var playlistName: String

  func perform() async throws -> some IntentResult {
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
struct AddToPlaylistIntent: AppIntent {
  static var title: LocalizedStringResource = "Add to Playlist"
  static var description = IntentDescription("Adds the currently playing song to a playlist.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Playlist Name")
  var playlistName: String

  func perform() async throws -> some IntentResult {
    let results = await SearchManager.shared.search(query: playlistName, filter: .playlists)
    
    await MainActor.run {
      if let playlist = results.playlists.first,
         let song = PlaybackController.shared.currentItem {
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
    AppShortcut(
      intent: PlayLikedSongsIntent(),
      phrases: [
        "Play liked songs in \(.applicationName)",
        "Start liked songs in \(.applicationName)",
      ],
      shortTitle: "Play Liked",
      systemImageName: "heart.fill"
    )
    AppShortcut(
      intent: ResumePlaybackIntent(),
      phrases: [
        "Resume music in \(.applicationName)",
        "Continue in \(.applicationName)",
      ],
      shortTitle: "Resume",
      systemImageName: "play.fill"
    )
    AppShortcut(
      intent: PlayMusicIntent(),
      phrases: [
        "Play music in \(.applicationName)",
        "Play in \(.applicationName)",
        "Search and play in \(.applicationName)"
      ],
      shortTitle: "Play Music",
      systemImageName: "magnifyingglass"
    )
    AppShortcut(
      intent: PlayArtistIntent(),
      phrases: [
        "Play an artist in \(.applicationName)",
        "Start artist music in \(.applicationName)"
      ],
      shortTitle: "Play Artist",
      systemImageName: "music.mic"
    )
    AppShortcut(
      intent: PlaySpecificPlaylistIntent(),
      phrases: [
        "Play a playlist in \(.applicationName)",
        "Start playlist in \(.applicationName)"
      ],
      shortTitle: "Play Playlist",
      systemImageName: "music.note.list"
    )
    AppShortcut(
      intent: LikeCurrentSongIntent(),
      phrases: [
        "Like this song in \(.applicationName)",
        "Favorite this song in \(.applicationName)"
      ],
      shortTitle: "Like Song",
      systemImageName: "heart"
    )
    AppShortcut(
      intent: AddToPlaylistIntent(),
      phrases: [
        "Add this to a playlist in \(.applicationName)",
        "Add this song to my playlist in \(.applicationName)"
      ],
      shortTitle: "Add to Playlist",
      systemImageName: "plus.circle"
    )
  }
}
