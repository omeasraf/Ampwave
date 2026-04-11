//
//  LibraryView.swift
//  Ampwave
//
//  Library view with tabs for Songs, Albums, Artists, and Playlists.
//

import SwiftData
internal import SwiftUI

struct LibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var selectedTab: LibraryTab = .songs
  @State private var searchText = ""

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  enum LibraryTab: String, CaseIterable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"

    var icon: String {
      switch self {
      case .songs: return "music.note"
      case .albums: return "square.stack"
      case .artists: return "person.2"
      case .playlists: return "list.bullet"
      }
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Tab picker
        Picker("Library Section", selection: $selectedTab) {
          ForEach(LibraryTab.allCases, id: \.self) { tab in
            Label(tab.rawValue, systemImage: tab.icon)
              .tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)

        // Content based on selected tab
        Group {
          switch selectedTab {
          case .songs:
            SongsListView(searchText: searchText)
          case .albums:
            AlbumsGridView(searchText: searchText)
          case .artists:
            ArtistsListView(searchText: searchText)
          case .playlists:
            PlaylistsListView(searchText: searchText)
          }
        }
      }
      .navigationTitle("Library")
      .searchable(text: $searchText, prompt: "Search in Library")
    }
    .onAppear {
      playlistManager.setModelContext(modelContext)
    }
  }
}

// MARK: - Songs List View

struct SongsListView: View {
  let searchText: String

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var filteredSongs: [LibrarySong] {
    if searchText.isEmpty {
      return library.songs
    }
    return library.songs.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.artist.localizedCaseInsensitiveContains(searchText)
        || ($0.album?.localizedCaseInsensitiveContains(searchText)
          ?? false)
    }
  }

  var body: some View {
    List {
      if !filteredSongs.isEmpty {
        Button {
          playback.playQueue(filteredSongs)
        } label: {
          Label("Play All", systemImage: "play.circle.fill")
            .font(.system(size: 16, weight: .semibold))
        }
        .listRowBackground(Color.clear)
      }

      ForEach(filteredSongs) { song in
        SongRow(
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(
            filteredSongs,
            startingAt: filteredSongs.firstIndex(where: {
              $0.id == song.id
            }) ?? 0
          )
        }
        .swipeActions(edge: .trailing) {
          Button {
            playlistManager.toggleLike(song: song)
          } label: {
            Image(
              systemName: playlistManager.isLiked(song: song)
                ? "heart.slash" : "heart"
            )
          }
          .tint(playlistManager.isLiked(song: song) ? .gray : .pink)
        }
        .swipeActions(edge: .leading) {
          Button {
            playback.playNext(song)
          } label: {
            Label("Play Next", systemImage: "text.insert")
          }
          .tint(.orange)
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if library.songs.isEmpty {
        ContentUnavailableView(
          "No Songs",
          systemImage: "music.note",
          description: Text(
            "Import songs from Settings to get started"
          )
        )
      } else if filteredSongs.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass",
          description: Text("No songs match your search")
        )
      }
    }
  }
}

// MARK: - Albums Grid View

struct AlbumsGridView: View {
  let searchText: String

  private var library: SongLibrary { SongLibrary.shared }

  var filteredAlbums: [Album] {
    if searchText.isEmpty {
      return library.albums
    }
    return library.albums.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || ($0.artist?.localizedCaseInsensitiveContains(searchText)
          ?? false)
    }
  }

  let columns = [
    GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)
  ]

  var body: some View {
    ScrollView {
      if filteredAlbums.isEmpty {
        ContentUnavailableView(
          library.albums.isEmpty ? "No Albums" : "No Results",
          systemImage: "square.stack",
          description: Text(
            library.albums.isEmpty
              ? "Import songs to see albums"
              : "No albums match your search"
          )
        )
        .padding(.top, 100)
      } else {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(filteredAlbums) { album in
            NavigationLink(destination: AlbumView(album: album)) {
              AlbumCard(album: album)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
      }
    }
  }
}

// MARK: - Album Card

// AlbumCard moved to Subviews/AlbumCard.swift - includes context menu support

// MARK: - Artists List View

struct ArtistsListView: View {
  let searchText: String
  @State private var artists: [Artist] = []

  private var library: SongLibrary { SongLibrary.shared }

  var filteredArtists: [Artist] {
    if searchText.isEmpty {
      return artists
    }
    return artists.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    List {
      ForEach(filteredArtists) { artist in
        NavigationLink(destination: ArtistView(artist: artist)) {
          HStack(spacing: 12) {
            ArtistImageView(
              artworkPath: artist.artworkPath,
              size: 50
            )

            VStack(alignment: .leading, spacing: 2) {
              Text(artist.name)
                .font(.system(size: 16, weight: .medium))

              Text(
                "\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")"
              )
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if artists.isEmpty {
        ContentUnavailableView(
          "No Artists",
          systemImage: "person.2",
          description: Text("Import songs to see artists")
        )
      } else if filteredArtists.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass",
          description: Text("No artists match your search")
        )
      }
    }
    .task {
      await loadArtists()
    }
  }

  private func loadArtists() async {
    artists = await library.allArtists()
  }
}

// MARK: - Playlists List View

struct PlaylistsListView: View {
  let searchText: String
  @State private var showingCreateSheet = false
  @State private var showUnpinAlert = false

  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var filteredPlaylists: [Playlist] {
    if searchText.isEmpty {
      return playlistManager.playlists
    }
    return playlistManager.playlists.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    List {
      Button {
        showingCreateSheet = true
      } label: {
        Label("New Playlist", systemImage: "plus.circle.fill")
          .font(.system(size: 16, weight: .semibold))
      }
      .listRowBackground(Color.clear)
      .sheet(isPresented: $showingCreateSheet) {
        CreatePlaylistSheet()
      }

      ForEach(filteredPlaylists) { playlist in
        NavigationLink(destination: PlaylistView(playlist: playlist)) {
          HStack(spacing: 12) {
            PlaylistArtworkView(
              playlist: playlist,
              size: 60
            )

            VStack(alignment: .leading, spacing: 2) {
              Text(playlist.name)
                .font(.system(size: 16, weight: .medium))

              Text(
                "\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")"
              )
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            }

            Spacer()

            if playlist.isPinned {
              Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
          }
        }
        .swipeActions(edge: .trailing) {
          if playlist.playlistType != .likedSongs {
            if playlist.playlistType == .custom
              || playlist.playlistType == .smart
            {
              Button(role: .destructive) {
                if playlist.isPinned {
                  showUnpinAlert = true
                } else {
                  playlistManager.deletePlaylist(playlist)
                }
              } label: {
                Label("Delete", systemImage: "trash")
              }
              .opacity(playlist.isPinned ? 0.5 : 1.0)  // Visual disable cue
            }

            Button {
              playlistManager.togglePin(playlist)
            } label: {
              Image(
                systemName: playlist.isPinned
                  ? "pin.slash" : "pin"
              )
            }
            .tint(.orange)
          }
        }
        .alert("Cannot Delete", isPresented: $showUnpinAlert) {
          Button("OK") {}
        } message: {
          Text("Unpin the playlist first.")
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if playlistManager.playlists.isEmpty {
        ContentUnavailableView(
          "No Playlists",
          systemImage: "list.bullet",
          description: Text("Create your first playlist")
        )
      } else if filteredPlaylists.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass",
          description: Text("No playlists match your search")
        )
      }
    }
  }
}

#Preview {
  LibraryView()
}
