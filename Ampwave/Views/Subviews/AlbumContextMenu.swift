//
//  AlbumContextMenu.swift
//  Ampwave
//
//  Reusable context menu actions for album-based views.
//

import SwiftData
internal import SwiftUI

struct AlbumContextMenuModifier: ViewModifier {
  let album: Album
  let onEdit: (() -> Void)?

  @State private var showingAddToPlaylist = false
  @State private var isDeletingShown = false
  @State private var showArtist = false
  @State private var showAlbum = false
  @Query private var userPreferences: [UserPreferences]

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }
  private var isAlbumFavorited: Bool {
    !album.songs.isEmpty && album.songs.allSatisfy { playlistManager.isLiked(song: $0) }
  }

  private var availablePlaylists: [Playlist] {
    playlistManager.playlists.filter { $0.playlistType != .likedSongs }
  }

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if let artistName = (self as? AlbumContextMenuModifier)?.album.artist
            ?? (self as? SongContextMenuModifier)?.song.artist,
            let artist = library.getArtist(named: artistName)
          {
            NavigationLink("", destination: ArtistView(artist: artist), isActive: $showArtist)
          }
          if let song = (self as? SongContextMenuModifier)?.song,
            let albumName = song.album,
            let album = library.getAlbum(named: albumName, artist: song.artist)
          {
            NavigationLink("", destination: AlbumView(album: album), isActive: $showAlbum)
          }
        }
        .hidden()
      }
      .contextMenu {
        Button {
          playback.playAlbum(album)
        } label: {
          Label("Play", systemImage: "play.fill")
        }

        Button {
          toggleAlbumFavorite()
        } label: {
          Label(
            isAlbumFavorited ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isAlbumFavorited ? "heart.slash" : "heart"
          )
        }

        if let artistName = album.artist, library.getArtist(named: artistName) != nil {
          Button {
            showArtist = true
          } label: {
            Label("Show Artist", systemImage: "person")
          }
        }

        Button {
          showingAddToPlaylist = true
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        if let onEdit {
          Button {
            onEdit()
          } label: {
            Label("Edit", systemImage: "pencil")
          }
        }

        #if os(iOS)
          Button {
            for song in album.songs {
              WatchSyncService.shared.updateSyncStatus(for: song, shouldSync: true)
            }
          } label: {
            Label("Sync Album to Watch", systemImage: "applewatch")
          }
        #endif

        Button(role: .destructive) {
          isDeletingShown = true
        } label: {
          Label("Delete Album", systemImage: "trash")
        }
      }
      .confirmationDialog("Add Album to Playlist", isPresented: $showingAddToPlaylist) {
        ForEach(availablePlaylists) { playlist in
          Button(playlist.name) {
            playlistManager.addAlbum(album, to: playlist)
          }
        }
      } message: {
        if availablePlaylists.isEmpty {
          Text("Create a playlist first from the Library tab.")
        } else {
          Text("Choose a playlist for this album.")
        }
      }
      .confirmationDialog(
        "Delete \"\(album.name)\"?",
        isPresented: $isDeletingShown,
        titleVisibility: .visible
      ) {
        Button(albumDeletesAudioFiles ? "Delete Album" : "Remove from Library", role: .destructive) {
          library.deleteAlbum(album)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        let count = album.songs.count
        let copiedCount = album.songs.count { $0.storageMode == .copied }
        let referencedCount = count - copiedCount
        if deletesReferencedOriginals && referencedCount > 0 {
          Text(
            "\(count) song\(count == 1 ? "" : "s") will be removed from Ampwave. Their original referenced files and any Ampwave copies will be permanently deleted."
          )
        } else if copiedCount > 0 {
          Text(
            "\(count) song\(count == 1 ? "" : "s") will be removed from Ampwave. \(copiedCount) copied audio file\(copiedCount == 1 ? "" : "s") will be deleted; referenced originals will stay where they are."
          )
        } else {
          Text(
            "\(count) song\(count == 1 ? "" : "s") will be removed from Ampwave. The audio files stay where they are on your device."
          )
        }
      }
  }

  /// True when any track in the album was copied into the app's storage, and
  /// so has a file that deletion will actually remove.
  private var albumHasCopiedFiles: Bool {
    album.songs.contains { $0.storageMode == .copied }
  }

  private var deletesReferencedOriginals: Bool {
    userPreferences.first?.deleteReferencedFilesOnRemoval ?? false
  }

  private var albumDeletesAudioFiles: Bool {
    albumHasCopiedFiles
      || (deletesReferencedOriginals && album.songs.contains { $0.storageMode == .referenced })
  }

  private func toggleAlbumFavorite() {
    let shouldFavorite = !isAlbumFavorited
    for song in album.songs {
      let isSongLiked = playlistManager.isLiked(song: song)
      if isSongLiked != shouldFavorite {
        _ = playlistManager.toggleLike(song: song)
      }
    }
  }
}

extension View {
  func albumContextMenu(album: Album, onEdit: (() -> Void)? = nil) -> some View {
    modifier(AlbumContextMenuModifier(album: album, onEdit: onEdit))
  }
}

struct SongContextMenuModifier: ViewModifier {
  let song: LibrarySong
  let onEdit: (() -> Void)?
  let onDelete: (() -> Void)?

  @State private var showingAddToPlaylist = false
  @State private var isEditingShown = false
  @State private var isDeletingShown = false
  @State private var showArtist = false
  @State private var showAlbum = false
  @Query private var userPreferences: [UserPreferences]

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }
  private var historyTracker: ListeningHistoryTracker { ListeningHistoryTracker.shared }

  private var availablePlaylists: [Playlist] {
    playlistManager.playlists.filter { $0.playlistType != .likedSongs }
  }

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if let artistName = (self as? AlbumContextMenuModifier)?.album.artist
            ?? (self as? SongContextMenuModifier)?.song.artist,
            let artist = library.getArtist(named: artistName)
          {
            NavigationLink("", destination: ArtistView(artist: artist), isActive: $showArtist)
          }
          if let song = (self as? SongContextMenuModifier)?.song,
            let albumName = song.album,
            let album = library.getAlbum(named: albumName, artist: song.artist)
          {
            NavigationLink("", destination: AlbumView(album: album), isActive: $showAlbum)
          }
        }
        .hidden()
      }
      .contextMenu {
        Button {
          playback.play(song)
        } label: {
          Label("Play", systemImage: "play.fill")
        }

        Button {
          HapticManager.shared.radioStart()
          playback.playRadio(from: song)
        } label: {
          Label("Go to Radio", systemImage: "antenna.radiowaves.left.and.right")
        }

        Button {
          if let onEdit {
            onEdit()
          } else {
            isEditingShown = true
          }
        } label: {
          Label("Edit", systemImage: "pencil")
        }

        Button {
          HapticManager.shared.like()
          _ = playlistManager.toggleLike(song: song)
        } label: {
          Label(
            playlistManager.isLiked(song: song) ? "Remove from Favorites" : "Add to Favorites",
            systemImage: playlistManager.isLiked(song: song) ? "heart.slash" : "heart"
          )
        }

        Button {
          HapticManager.shared.dislike()
          _ = playlistManager.toggleDisliked(song: song)
        } label: {
          Label(
            playlistManager.isDisliked(song: song) ? "Clear Dislike" : "Dislike Song",
            systemImage: playlistManager.isDisliked(song: song) ? "hand.thumbsdown.slash" : "hand.thumbsdown"
          )
        }

        Menu {
          Button("Clear Rating") {
            historyTracker.setRating(nil, for: song)
          }
          ForEach(1...5, id: \.self) { rating in
            Button(String(repeating: "★", count: rating)) {
              historyTracker.setRating(rating, for: song)
            }
          }
        } label: {
          let currentRating = historyTracker.rating(for: song) ?? 0
          Label(
            currentRating > 0 ? "Rating: \(currentRating)/5" : "Rate Song",
            systemImage: "star"
          )
        }

        if library.getArtist(named: song.artist) != nil {
          Button {
            showArtist = true
          } label: {
            Label("Show Artist", systemImage: "person")
          }
        }

        if let albumName = song.album,
          let album = library.getAlbum(named: albumName, artist: song.artist)
        {
          Button {
            showAlbum = true
          } label: {
            Label("Show Album", systemImage: "square.stack")
          }
        }

        Button {
          showingAddToPlaylist = true
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        #if os(iOS)
          Button {
            WatchSyncService.shared.updateSyncStatus(for: song, shouldSync: !song.shouldSyncToWatch)
          } label: {
            Label(
              song.shouldSyncToWatch ? "Remove from Watch" : "Sync to Watch",
              systemImage: song.shouldSyncToWatch ? "applewatch.slash" : "applewatch"
            )
          }
        #endif

        Button {
          if let onDelete {
            onDelete()
          } else {
            isDeletingShown = true
          }
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
      .sheet(isPresented: $isEditingShown) {
        SongEditSheet(song: song, isPresented: $isEditingShown)
      }
      .confirmationDialog("Add Song to Playlist", isPresented: $showingAddToPlaylist) {
        ForEach(availablePlaylists) { playlist in
          Button(playlist.name) {
            playlistManager.addSong(song, to: playlist)
          }
        }
      } message: {
        if availablePlaylists.isEmpty {
          Text("Create a playlist first from the Library tab.")
        } else {
          Text("Choose a playlist for this song.")
        }
      }
      .confirmationDialog(
        "Delete \"\(song.title)\"?",
        isPresented: $isDeletingShown,
        titleVisibility: .visible
      ) {
        Button(songDeletesAudioFile ? "Delete Song" : "Remove from Library",
          role: .destructive
        ) {
          if let onDelete {
            onDelete()
          } else {
            library.deleteSong(song)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        if song.storageMode == .copied {
          Text(
            "The audio file will be deleted from your device, along with this song's play history and lyrics."
          )
        } else if deletesReferencedOriginals {
          Text(
            "This removes the song from Ampwave and permanently deletes the original referenced audio file, along with its play history and lyrics."
          )
        } else {
          Text(
            "This removes the song from Ampwave along with its play history. The audio file stays where it is on your device."
          )
        }
      }
  }

  private var deletesReferencedOriginals: Bool {
    userPreferences.first?.deleteReferencedFilesOnRemoval ?? false
  }

  private var songDeletesAudioFile: Bool {
    song.storageMode == .copied || deletesReferencedOriginals
  }
}

extension View {
  func songContextMenu(
    song: LibrarySong, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil
  ) -> some View {
    modifier(SongContextMenuModifier(song: song, onEdit: onEdit, onDelete: onDelete))
  }
}
