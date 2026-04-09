//
//  AlbumContextMenu.swift
//  Ampwave
//
//  Reusable context menu actions for album-based views.
//

internal import SwiftUI

struct AlbumContextMenuModifier: ViewModifier {
  let album: Album
  let onEdit: (() -> Void)?

  @State private var showingAddToPlaylist = false

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var isAlbumFavorited: Bool {
    !album.songs.isEmpty && album.songs.allSatisfy { playlistManager.isLiked(song: $0) }
  }

  private var availablePlaylists: [Playlist] {
    playlistManager.playlists.filter { $0.playlistType != .likedSongs }
  }

  func body(content: Content) -> some View {
    content
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

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var availablePlaylists: [Playlist] {
    playlistManager.playlists.filter { $0.playlistType != .likedSongs }
  }

  func body(content: Content) -> some View {
    content
      .contextMenu {
        Button {
          playback.play(song)
        } label: {
          Label("Play", systemImage: "play.fill")
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
          _ = playlistManager.toggleLike(song: song)
        } label: {
          Label(
            playlistManager.isLiked(song: song) ? "Remove from Favorites" : "Add to Favorites",
            systemImage: playlistManager.isLiked(song: song) ? "heart.slash" : "heart"
          )
        }

        Button {
          showingAddToPlaylist = true
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }
          
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
  }
}

extension View {
  func songContextMenu(song: LibrarySong, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) -> some View {
      modifier(SongContextMenuModifier(song: song, onEdit: onEdit, onDelete: onDelete))
  }
}
