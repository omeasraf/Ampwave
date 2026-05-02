//
//  HomeView.swift
//  Ampwave
//
//  Enhanced home view with For You recommendations, recently played, and quick access.
//  Fixed recommendations display.
//

import SwiftData
internal import SwiftUI

struct HomeView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Environment(ThemeManager.self) private var themeManager

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var historyTracker: ListeningHistoryTracker {
    ListeningHistoryTracker.shared
  }
  private var recommendationEngine: RecommendationEngine {
    RecommendationEngine.shared
  }

  @State private var forYouRecommendations: [Recommendation] = []
  @State private var recentlyPlayedSongs: [LibrarySong] = []
  @State private var mostPlayedSongs: [(song: LibrarySong, count: Int)] = []
  @State private var isLoading = true
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var hasLoadedInitialData = false

  private var recentlyAdded: [LibrarySong] {
    Array(library.songs.prefix(10))
  }

  private var indexingMessage: String? {
    switch library.indexingStatus {
    case .complete, .idle:
      return "Loading your library..."
    @unknown default:
      return nil
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        // Welcome header
        welcomeHeader

        if library.songs.isEmpty
          && (isLoading || library.indexingStatus != .complete)
        {
          if indexingMessage != nil {
            VStack(spacing: 20) {
              Spacer()
                .frame(height: 100)
              ProgressView()
                .scaleEffect(1.5)
              Text(indexingMessage!)
                .foregroundStyle(.secondary)
              Spacer()
            }
            .frame(maxWidth: .infinity)
          }
        } else if library.songs.isEmpty {
          emptyState
        } else {
          // Status indicator for background activity
          if library.indexingStatus != .complete {
            if indexingMessage != nil {
              HStack {
                ProgressView()
                  .controlSize(.small)
                  .padding(.trailing, 4)
                Text(indexingMessage!)
                  .font(.system(size: 13))
                  .foregroundStyle(.secondary)
                Spacer()
              }
              .padding(.horizontal, 20)
              .padding(.top, -10)
            }
          }

          // Recently Played section
          if !recentlyPlayedSongs.isEmpty {
            HorizontalSongSection(
              title: "Recently Played",
              songs: recentlyPlayedSongs,
              onSongPlayed: refreshHomeSections
            )
          }

          // For You recommendations
          if !forYouRecommendations.isEmpty {
            RecommendationsSection(
              recommendations: forYouRecommendations,
              onSongPlayed: refreshHomeSections
            )
          }

          // Most Played section
          if !mostPlayedSongs.isEmpty {
            HorizontalSongSection(
              title: "Your Top Songs",
              songs: mostPlayedSongs.map { $0.song },
              onSongPlayed: refreshHomeSections
            )
          }

          // Recently Added section
          if !recentlyAdded.isEmpty {
            HorizontalSongSection(
              title: "Recently Added",
              songs: recentlyAdded,
              onSongPlayed: refreshHomeSections
            )
          }

          // Quick access playlists
          QuickAccessSection()

          // Browse by section
          BrowseSection()
        }
      }
      .padding(.vertical, 20)
    }
    .background(themeManager.backgroundColor)
    .navigationTitle("Home")
    .task {
      // Only load data once on initial appearance
      if !hasLoadedInitialData {
        print("[DEBUG] HomeView.task - loadData starting")
        let loadStart = Date()
        await loadData()
        print(
          "[DEBUG] HomeView.task - loadData finished (took \(Date().timeIntervalSince(loadStart))s)"
        )
        hasLoadedInitialData = true
      }
    }
    .onAppear {
      print("[DEBUG] HomeView.onAppear")
      refreshHomeSections()
      // Update recommendations when appearing to ensure they are fresh
      Task {
        await recommendationEngine.generateAllRecommendations()
        forYouRecommendations =
          recommendationEngine.forYouRecommendations
      }
    }
    .refreshable {
      await loadData(forceRefresh: true)
    }
    .onChange(of: library.songs) {
      print(
        "[DEBUG] HomeView.onChange(library.songs) - Updating recommendations"
      )
      refreshHomeSections()
      Task {
        await recommendationEngine.generateAllRecommendations()
        forYouRecommendations =
          recommendationEngine.forYouRecommendations
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        refreshHomeSections()
      }
    }
    .onChange(of: playback.currentItem) {
      print("[DEBUG] HomeView.onChange(playback.currentItem) - Refreshing history")
      refreshHomeSections()
    }
    .alert("Error", isPresented: $showError) {
      Button("OK") {}
    } message: {
      Text(errorMessage)
    }
  }

  private var welcomeHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(greeting)
          .font(.system(size: 28, weight: .bold))

        if !library.songs.isEmpty {
          Text("\(library.songs.count) songs in your library")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
    .padding(.horizontal, 20)
  }

  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 0..<12: return "Good morning"
    case 12..<17: return "Good afternoon"
    default: return "Good evening"
    }
  }

  private var emptyState: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "music.note.house")
        .font(.system(size: 80))
        .foregroundStyle(.secondary)

      Text("Welcome to Ampwave")
        .font(.system(size: 24, weight: .bold))

      Text(
        "Import your music to get started. Your library works fully offline."
      )
      .font(.system(size: 16))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 40)

      NavigationLink(destination: SettingsView()) {
        HStack {
          Image(systemName: "plus.circle")
          Text("Import Music")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.pink)
        .clipShape(Capsule())
      }

      Spacer()
    }
    .padding()
  }

  private func loadData(forceRefresh: Bool = false) async {
    isLoading = true

    do {
      // Ensure contexts are set
      historyTracker.setModelContext(modelContext)
      playlistManager.setModelContext(modelContext)
      recommendationEngine.setModelContext(modelContext)

      // If library is already indexing, wait for it
      if !forceRefresh && library.indexingStatus != .complete {
        print(
          "[DEBUG] HomeView.loadData: Library is indexing, waiting..."
        )
        while library.indexingStatus != .complete {
          try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
        }
      }

      // Load library if needed
      if library.songs.isEmpty || forceRefresh {
        await library.loadSongs()
      }

      // Generate recommendations
      await recommendationEngine.generateAllRecommendations(
        forceRefresh: forceRefresh
      )
      forYouRecommendations = recommendationEngine.forYouRecommendations
      refreshHomeSections()
    } catch {
      errorMessage = error.localizedDescription
      showError = true
    }

    isLoading = false
  }

  private func refreshHomeSections() {
    recentlyPlayedSongs = historyTracker.getRecentlyPlayed(limit: 10)
    mostPlayedSongs = historyTracker.getMostPlayed(limit: 10)
  }
}

// MARK: - Horizontal Song Section

struct HorizontalSongSection: View {
  let title: String
  let songs: [LibrarySong]
  var onSongPlayed: (() -> Void)? = nil
  @Environment(ThemeManager.self) private var themeManager

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title)
          .font(.system(size: 22, weight: .bold))

        Spacer()
      }
      .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(songs) { song in
            SongCard(song: song)
              .onTapGesture {
                playback.playQueue(
                  songs,
                  startingAt: songs.firstIndex(where: {
                    $0.id == song.id
                  }) ?? 0
                )
                onSongPlayed?()
              }
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .padding(.vertical, 8)
    .background(themeManager.backgroundColor)
  }
}

// MARK: - Song Card

struct SongCard: View {
  let song: LibrarySong

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AlbumArtworkView(artworkPath: song.artworkPath, size: 140)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 140, alignment: .leading)
    }
    .songContextMenu(song: song)
  }
}

// MARK: - Recommendations Section

struct RecommendationsSection: View {
  let recommendations: [Recommendation]
  let onSongPlayed: () -> Void

  private var playback: PlaybackController { PlaybackController.shared }
  private var recommendationSongs: [LibrarySong] {
    recommendations.compactMap {
      if case .song(let song) = $0.item {
        return song
      }
      return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      //      Text("Made For You")
      //        .font(.system(size: 22, weight: .bold))
      //        .padding(.horizontal, 20)
      //
      //      ScrollView(.horizontal, showsIndicators: false) {
      //        LazyHStack(spacing: 16) {
      //          ForEach(recommendations.prefix(10)) { recommendation in
      //            RecommendationCard(recommendation: recommendation)
      //              .onTapGesture {
      //                switch recommendation.item {
      //                case .song(let song):
      //                  if let index = recommendationSongs.firstIndex(where: { $0.id == song.id }) {
      //                    playback.playQueue(
      //                      recommendationSongs,
      //                      startingAt: index,
      //                      from: .recommendation
      //                    )
      //                    onSongPlayed()
      //                  } else {
      //                    playback.play(song, from: .recommendation)
      //                    onSongPlayed()
      //                  }
      //                case .album(let album):
      //                  playback.playAlbum(album)
      //                case .artist(let artist):
      //                  // Play artist's songs (including featured artists)
      //                  let artistSongs = SongLibrary.shared.getSongs(byArtist: artist.name)
      //                  if !artistSongs.isEmpty {
      //                    playback.playQueue(artistSongs)
      //                  }
      //                case .playlist(let playlist):
      //                  playback.playPlaylist(playlist)
      //                }
      //              }
      //          }
      //        }
      //        .padding(.horizontal, 20)
      //      }

      // MARK: Made for you

      Text("Made For You")
        .font(.system(size: 22, weight: .bold))
        .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(recommendations.prefix(10)) { recommendation in
            RecommendationCard(recommendation: recommendation)
              .onTapGesture {
                switch recommendation.item {
                case .song(let song):
                  if let index =
                    recommendationSongs.firstIndex(where: {
                      $0.id == song.id
                    })
                  {
                    playback.playQueue(
                      recommendationSongs,
                      startingAt: index,
                      from: .recommendation
                    )
                    onSongPlayed()
                  } else {
                    playback.play(
                      song,
                      from: .recommendation
                    )
                    onSongPlayed()
                  }
                case .album(let album):
                  playback.playAlbum(album)
                case .artist(let artist):
                  // Play artist's songs (including featured artists)
                  let artistSongs = SongLibrary.shared
                    .getSongs(byArtist: artist.name)
                  if !artistSongs.isEmpty {
                    playback.playQueue(artistSongs)
                  }
                case .playlist(let playlist):
                  playback.playPlaylist(playlist)
                }
              }
          }
        }
        .padding(.horizontal, 20)
      }

      // End Made for you
    }
  }
}

// MARK: - Recommendation Card

struct RecommendationCard: View {
  let recommendation: Recommendation

  var body: some View {
    if let album = albumForContextMenu {
      cardContent
        .albumContextMenu(album: album)
    } else if let song = songForContextMenu {
      cardContent
        .songContextMenu(song: song)
    } else {
      cardContent
    }
  }

  private var title: String {
    switch recommendation.item {
    case .song(let song): return song.title
    case .album(let album): return album.name
    case .artist(let artist): return artist.name
    case .playlist(let playlist): return playlist.name
    }
  }

  private var albumForContextMenu: Album? {
    if case .album(let album) = recommendation.item {
      return album
    }
    return nil
  }

  private var songForContextMenu: LibrarySong? {
    if case .song(let song) = recommendation.item {
      return song
    }
    return nil
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        switch recommendation.item {
        case .song(let song):
          AlbumArtworkView(artworkPath: song.artworkPath, size: 160)
        case .album(let album):
          AlbumArtworkView(artworkPath: album.artworkPath, size: 160)
        case .artist(let artist):
          ArtistImageView(artworkPath: artist.artworkPath, size: 160)
        case .playlist(let playlist):
          AlbumArtworkView(
            artworkPath: playlist.artworkPath,
            size: 160
          )
        }
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)

        Text(recommendation.reason.displayText)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: 160, height: 60, alignment: .topLeading)
    }
  }
}

// MARK: - Quick Access Section

struct QuickAccessSection: View {
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  @State private var likedSongsPlaylist: Playlist?
  @State private var isLoadingQuickAccess = false

  var body: some View {
    print("[DEBUG] QuickAccessSection.body rendering")
    return VStack(alignment: .leading, spacing: 12) {
      Text("Quick Access")
        .font(.system(size: 22, weight: .bold))
        .padding(.horizontal, 20)

      if !isLoadingQuickAccess {
        LazyVGrid(
          columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
          ],
          spacing: 12
        ) {
          if let likedSongs = likedSongsPlaylist,
            !likedSongs.songs.isEmpty
          {
            QuickAccessButton(
              title: "Liked Songs",
              subtitle: "\(likedSongs.songCount) songs",
              icon: "heart.fill",
              color: .pink
            ) {
              playback.playPlaylist(likedSongs)
            }
          }

          QuickAccessButton(
            title: "Shuffle All",
            subtitle: "Random playback",
            icon: "shuffle",
            color: .blue
          ) {
            playback.shuffleMode = .on
            playback.playQueue(SongLibrary.shared.songs.shuffled())
          }

          QuickAccessButton(
            title: "Recently Added",
            subtitle: "New in library",
            icon: "clock",
            color: .orange
          ) {
            let recent = SongLibrary.shared.songs.prefix(50).map {
              $0
            }
            playback.playQueue(recent)
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .task {
      print("[DEBUG] QuickAccessSection loading data")
      isLoadingQuickAccess = true
      let start = Date()
      likedSongsPlaylist = playlistManager.likedSongsPlaylist
      print(
        "[DEBUG] QuickAccessSection loaded (took \(Date().timeIntervalSince(start))s)"
      )
      isLoadingQuickAccess = false
    }
  }
}

// MARK: - Quick Access Button

struct QuickAccessButton: View {
  let title: String
  let subtitle: String
  let icon: String
  let color: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 20))
          .foregroundStyle(color)
          .frame(width: 40, height: 40)
          .background(color.opacity(0.15))
          .clipShape(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding()
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Browse Section

struct BrowseSection: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Browse")
        .font(.system(size: 22, weight: .bold))
        .padding(.horizontal, 20)

      Text("Jump to albums, artists, playlists, or genres")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 12) {
          BrowseCard(title: "Albums", icon: "square.stack", color: .purple) {
            LibraryView(initialTab: .albums)
          }
          BrowseCard(title: "Artists", icon: "person.2", color: .pink) {
            LibraryView(initialTab: .artists)
          }
          BrowseCard(title: "Playlists", icon: "list.bullet", color: .cyan) {
            PlaylistsListView()
          }
          BrowseCard(title: "Genres", icon: "tag", color: .indigo) {
            GenresBrowseView()
          }
        }
        .padding(.horizontal, 20)
      }
    }
  }
}

// MARK: - Browse Card

struct BrowseCard<Destination: View>: View {
  let title: String
  let icon: String
  let color: Color
  @ViewBuilder var destination: () -> Destination

  var body: some View {
    NavigationLink(destination: destination()) {
      VStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 28))
          .foregroundStyle(color)

        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .multilineTextAlignment(.center)
      }
      .frame(width: 100, height: 100)
      .background(color.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Genres Browse

struct GenresBrowseView: View {
  @Environment(ThemeManager.self) private var themeManager
  private var library: SongLibrary { SongLibrary.shared }

  private var genres: [String] {
    var unique = Set<String>()
    for song in library.songs {
      guard let raw = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
      else { continue }
      for part in raw.split(separator: "/") {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { unique.insert(trimmed) }
      }
    }
    return unique.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  var body: some View {
    Group {
      if genres.isEmpty {
        ContentUnavailableView(
          "No Genres Yet",
          systemImage: "tag",
          description: Text(
            "Genres appear when your tracks have genre metadata. Try editing a song or enabling metadata fetch in Settings."
          )
        )
      } else {
        List {
          ForEach(genres, id: \.self) { genre in
            NavigationLink(destination: GenreSongsView(genre: genre)) {
              HStack {
                Image(systemName: "tag.fill")
                  .foregroundStyle(themeManager.accentColor)
                  .frame(width: 28)
                Text(genre)
                  .font(.system(size: 16, weight: .medium))
              }
            }
            .listRowBackground(themeManager.backgroundColor)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .background(themeManager.backgroundColor)
    .navigationTitle("Genres")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

struct GenreSongsView: View {
  let genre: String
  @Environment(ThemeManager.self) private var themeManager
  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var songs: [LibrarySong] {
    library.songs.filter { songMatchesGenre($0) }
      .sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
  }

  private func songMatchesGenre(_ song: LibrarySong) -> Bool {
    guard let g = song.genre, !g.isEmpty else { return false }
    let needle = genre.lowercased()
    let parts = g.split(separator: "/").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    if parts.contains(needle) { return true }
    return g.lowercased().contains(needle)
  }

  var body: some View {
    List {
      ForEach(songs) { song in
        SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
          .contentShape(Rectangle())
          .onTapGesture {
            playback.playQueue(
              songs,
              startingAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0
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
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .navigationTitle(genre)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .overlay {
      if songs.isEmpty {
        ContentUnavailableView(
          "No Songs",
          systemImage: "music.note",
          description: Text("No tracks match this genre label.")
        )
      }
    }
  }
}

#Preview {
  NavigationStack {
    HomeView()
  }
}
