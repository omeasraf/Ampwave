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
  @Query private var settings: [AppSettings]
  @State private var selectedTab: LibraryTab = .songs
  @State private var searchText = ""

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  
  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

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
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
          sortMenu
      }
      .searchable(text: $searchText, prompt: "Search in Library")
    }
    .onAppear {
      playlistManager.setModelContext(modelContext)
    }
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort Order", selection: currentSortBinding) {
        ForEach(availableSortOrders, id: \.self) { order in
          Label(order.rawValue, systemImage: order.icon).tag(order)
        }
      }
    } label: {
      Image(systemName: "arrow.up.arrow.down.circle")
    }
  }

  private var currentSortBinding: Binding<LibrarySortOrder> {
    switch selectedTab {
    case .songs:
      return Binding(
        get: { appSettings.songSortOrder },
        set: { appSettings.songSortOrder = $0 }
      )
    case .albums:
      return Binding(
        get: { appSettings.albumSortOrder },
        set: { appSettings.albumSortOrder = $0 }
      )
    case .artists:
      return Binding(
        get: { appSettings.artistSortOrder },
        set: { appSettings.artistSortOrder = $0 }
      )
    case .playlists:
      return Binding(
        get: { appSettings.playlistSortOrder },
        set: { appSettings.playlistSortOrder = $0 }
      )
    }
  }

  private var availableSortOrders: [LibrarySortOrder] {
    switch selectedTab {
    case .songs:
      return [
        .titleAscending, .titleDescending, .artistAscending, .artistDescending,
        .dateAddedDescending, .dateAddedAscending, .yearDescending, .yearAscending,
      ]
    case .albums:
      return [
        .titleAscending, .titleDescending, .artistAscending, .artistDescending,
        .dateAddedDescending, .yearDescending, .yearAscending,
      ]
    case .artists:
      return [.titleAscending, .titleDescending, .dateAddedDescending]
    case .playlists:
      return [.titleAscending, .titleDescending, .dateAddedDescending, .dateAddedAscending]
    }
  }
}

// MARK: - Songs List View

struct SongsListView: View {
  let searchText: String
  @Environment(\.modelContext) private var modelContext
  @Query private var settings: [AppSettings]

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  
  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  var filteredSongs: [LibrarySong] {
    let songs: [LibrarySong]
    if searchText.isEmpty {
      songs = library.songs
    } else {
      songs = library.songs.filter {
        $0.title.localizedCaseInsensitiveContains(searchText)
          || $0.artist.localizedCaseInsensitiveContains(searchText)
          || ($0.album?.localizedCaseInsensitiveContains(searchText)
            ?? false)
      }
    }
    
    return sortSongs(songs)
  }
  
  private func sortSongs(_ songs: [LibrarySong]) -> [LibrarySong] {
    switch appSettings.songSortOrder {
    case .titleAscending:
      return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .titleDescending:
      return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
    case .artistAscending:
      return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
    case .artistDescending:
      return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedDescending }
    case .dateAddedDescending:
      return songs.sorted { $0.importedDate > $1.importedDate }
    case .dateAddedAscending:
      return songs.sorted { $0.importedDate < $1.importedDate }
    case .yearDescending:
      return songs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .yearAscending:
      return songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
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
  @Environment(\.modelContext) private var modelContext
  @Query private var settings: [AppSettings]

  private var library: SongLibrary { SongLibrary.shared }
  
  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  var filteredAlbums: [Album] {
    let albums: [Album]
    if searchText.isEmpty {
      albums = library.albums
    } else {
      albums = library.albums.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
          || ($0.artist?.localizedCaseInsensitiveContains(searchText)
            ?? false)
      }
    }
    
    return sortAlbums(albums)
  }
  
  private func sortAlbums(_ albums: [Album]) -> [Album] {
    switch appSettings.albumSortOrder {
    case .titleAscending:
      return albums.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .titleDescending:
      return albums.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
    case .artistAscending:
      return albums.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
    case .artistDescending:
      return albums.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedDescending }
    case .dateAddedDescending:
      return albums.sorted { $0.createdDate > $1.createdDate }
    case .dateAddedAscending:
      return albums.sorted { $0.createdDate < $1.createdDate }
    case .yearDescending:
      return albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .yearAscending:
      return albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
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
  @Environment(\.modelContext) private var modelContext
  @Query private var settings: [AppSettings]
  @State private var artists: [Artist] = []

  private var library: SongLibrary { SongLibrary.shared }
  
  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  var filteredArtists: [Artist] {
    let artistsToFilter: [Artist]
    if searchText.isEmpty {
      artistsToFilter = artists
    } else {
      artistsToFilter = artists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }
    
    return sortArtists(artistsToFilter)
  }
  
  private func sortArtists(_ artists: [Artist]) -> [Artist] {
    switch appSettings.artistSortOrder {
    case .titleAscending:
      return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .titleDescending:
      return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
    case .dateAddedDescending:
      return artists.sorted { $0.lastAddedDate > $1.lastAddedDate }
    default:
      return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
  @Environment(\.modelContext) private var modelContext
  @Query private var settings: [AppSettings]
  @State private var showingCreateSheet = false
  @State private var showUnpinAlert = false

  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  
  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  var filteredPlaylists: [Playlist] {
    let playlists: [Playlist]
    if searchText.isEmpty {
      playlists = playlistManager.playlists
    } else {
      playlists = playlistManager.playlists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }
    
    return sortPlaylists(playlists)
  }
  
  private func sortPlaylists(_ playlists: [Playlist]) -> [Playlist] {
    // We want to keep Liked Songs and Pinned playlists at top, then apply sort
    var sorted = playlists
    
    sorted.sort { p1, p2 in
      // 1. Liked Songs always at the top
      if p1.playlistType == .likedSongs && p2.playlistType != .likedSongs { return true }
      if p2.playlistType == .likedSongs && p1.playlistType != .likedSongs { return false }

      // 2. Pinned playlists next
      if p1.isPinned != p2.isPinned {
        return p1.isPinned && !p2.isPinned
      }
      
      // 3. Apply user's selected sort order for the rest
      switch appSettings.playlistSortOrder {
      case .titleAscending:
        return p1.name.localizedCaseInsensitiveCompare(p2.name) == .orderedAscending
      case .titleDescending:
        return p1.name.localizedCaseInsensitiveCompare(p2.name) == .orderedDescending
      case .dateAddedDescending:
        return p1.createdDate > p2.createdDate
      case .dateAddedAscending:
        return p1.createdDate < p2.createdDate
      default:
        return p1.name.localizedCaseInsensitiveCompare(p2.name) == .orderedAscending
      }
    }
    
    return sorted
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
