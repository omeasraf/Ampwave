//
//  LibraryView.swift
//  Ampwave
//
//  Library view with tabs for Songs, Albums, Artists, and Playlists.
//

import SwiftData
internal import SwiftUI

struct LibrarySortMenu: View {
  let selectedTab: LibraryView.LibraryTab
  @Bindable var appSettings: AppSettings

  var body: some View {
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
    case .genres:
      return Binding(
        get: { appSettings.songSortOrder },
        set: { appSettings.songSortOrder = $0 }
      )
    }
  }

  private var availableSortOrders: [LibrarySortOrder] {
    switch selectedTab {
    case .songs:
      return [
        .titleAscending, .titleDescending, .artistAscending, .artistDescending,
        .dateAddedDescending, .dateAddedAscending, .yearDescending, .yearAscending, .random,
      ]
    case .albums:
      return [
        .titleAscending, .titleDescending, .artistAscending, .artistDescending,
        .dateAddedDescending, .yearDescending, .yearAscending, .random,
      ]
    case .artists:
      return [.titleAscending, .titleDescending, .dateAddedDescending, .random]
    case .genres:
      return []
    }
  }
}

// MARK: - Genres grid (Library tab + Genres browse)

struct GenresGridView: View {
  var searchText: String = ""
  @Environment(ThemeManager.self) private var themeManager
  private var library: SongLibrary { SongLibrary.shared }

  private var entries: [(name: String, count: Int)] {
    let base = library.genreEntriesSortedByPopularity()
    guard !searchText.isEmpty else { return base }
    return base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
  }

  private let columns = [
    GridItem(.flexible(), spacing: 14),
    GridItem(.flexible(), spacing: 14),
  ]

  var body: some View {
    Group {
      if entries.isEmpty {
        ContentUnavailableView(
          library.songs.isEmpty ? "No Genres" : "No Results",
          systemImage: "tag",
          description: Text(
            library.songs.isEmpty
              ? "Import songs with genre metadata to see genres here."
              : "No genres match your search."
          )
        )
        .padding(.top, 48)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(entries, id: \.name) { entry in
              NavigationLink {
                GenreSongsView(genre: entry.name)
              } label: {
                genreCell(name: entry.name, count: entry.count)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 12)
        }
      }
    }
    .background(themeManager.backgroundColor)
  }

  private func genreCell(name: String, count: Int) -> some View {
    let colors = GenrePalette.gradient(for: name)
    return ZStack(alignment: .bottomLeading) {
      LinearGradient(
        colors: colors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      LinearGradient(
        colors: [.black.opacity(0.06), .black.opacity(0.42)],
        startPoint: .top,
        endPoint: .bottom
      )
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.title2.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(3)
          .minimumScaleFactor(0.72)
        Text("\(count) songs")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white.opacity(0.92))
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, minHeight: 124)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(name), \(count) songs")
    .accessibilityHint("View songs in this genre")
  }
}

struct LibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @State private var selectedTab: LibraryTab
  @State private var searchText = ""

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  init(initialTab: LibraryTab = .songs) {
    _selectedTab = State(initialValue: initialTab)
  }

  enum LibraryTab: String, CaseIterable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case genres = "Genres"

    var icon: String {
      switch self {
      case .songs: return "music.note"
      case .albums: return "square.stack"
      case .artists: return "person.2"
      case .genres: return "tag.fill"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Tab picker
      Picker("Library Section", selection: $selectedTab) {
        ForEach(LibraryTab.allCases, id: \.self) { tab in
          Label(tab.rawValue, systemImage: tab.icon)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .tint(themeManager.accentColor)
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
        case .genres:
          GenresGridView(searchText: searchText)
        }
      }
    }
    .background(themeManager.backgroundColor)
    .tint(themeManager.accentColor)
    .navigationTitle("Library")
    .toolbar {
      if selectedTab != .genres {
        LibrarySortMenu(selectedTab: selectedTab, appSettings: appSettings)
      }
    }
    .searchable(text: $searchText, prompt: "Search songs, artists, albums, lyrics...")
    .onAppear {
      playlistManager.setModelContext(modelContext)
    }
  }
}

// MARK: - Songs List View

struct SongsListView: View {
  let searchText: String
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
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
      songs = library.songs.filter { song in
        // Check basic fields
        let basicMatch =
          song.title.localizedCaseInsensitiveContains(searchText)
          || song.artist.localizedCaseInsensitiveContains(searchText)
          || (song.album?.localizedCaseInsensitiveContains(searchText) ?? false)

        // Only check lyrics for longer search terms to avoid performance issues
        if searchText.count >= 3 {
          // Check plain lyrics
          let lyricsMatch = song.lyrics?.localizedCaseInsensitiveContains(searchText) ?? false

          // Check synced lyrics
          let syncedLyricsMatch =
            LyricsService.shared.getCachedLyrics(for: song)?
            .lines.contains { $0.text.localizedCaseInsensitiveContains(searchText) } ?? false

          return basicMatch || lyricsMatch || syncedLyricsMatch
        } else {
          return basicMatch
        }
      }
    }

    return sortSongs(songs)
  }

  private func sortSongs(_ songs: [LibrarySong]) -> [LibrarySong] {
    switch appSettings.songSortOrder {
    case .titleAscending:
      return songs.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    case .titleDescending:
      return songs.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
      }
    case .artistAscending:
      return songs.sorted {
        $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
      }
    case .artistDescending:
      return songs.sorted {
        $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedDescending
      }
    case .dateAddedDescending:
      return songs.sorted { $0.importedDate > $1.importedDate }
    case .dateAddedAscending:
      return songs.sorted { $0.importedDate < $1.importedDate }
    case .yearDescending:
      return songs.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .yearAscending:
      return songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    case .random:
      return songs.sorted { $0.id.uuidString < $1.id.uuidString }
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
        .listRowBackground(themeManager.backgroundColor)
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
        .listRowBackground(themeManager.backgroundColor)
        .swipeActions(edge: .trailing) {
          Button {
            playlistManager.toggleLike(song: song)
          } label: {
            Image(
              systemName: playlistManager.isLiked(song: song)
                ? "heart.slash" : "heart"
            )
          }
          .tint(playlistManager.isLiked(song: song) ? .gray : themeManager.accentColor)
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
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
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
  @Environment(ThemeManager.self) private var themeManager
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
      return albums.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
      }
    case .artistAscending:
      return albums.sorted {
        ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending
      }
    case .artistDescending:
      return albums.sorted {
        ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedDescending
      }
    case .dateAddedDescending:
      return albums.sorted { $0.createdDate > $1.createdDate }
    case .dateAddedAscending:
      return albums.sorted { $0.createdDate < $1.createdDate }
    case .yearDescending:
      return albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .yearAscending:
      return albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    case .random:
      return albums.sorted { $0.id.uuidString < $1.id.uuidString }
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
    .background(themeManager.backgroundColor)
  }
}

// MARK: - Album Card

// AlbumCard moved to Subviews/AlbumCard.swift - includes context menu support

// MARK: - Artists List View

struct ArtistsListView: View {
  let searchText: String
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
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
      return artists.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    case .titleDescending:
      return artists.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
      }
    case .dateAddedDescending:
      return artists.sorted { $0.lastAddedDate > $1.lastAddedDate }
    case .random:
      return artists.sorted { $0.id.uuidString < $1.id.uuidString }
    default:
      return artists.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
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
        .listRowBackground(themeManager.backgroundColor)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
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

#Preview {
  LibraryView()
}
