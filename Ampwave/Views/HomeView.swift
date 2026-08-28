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
  @State private var genreRecommendations: [Recommendation] = []
  @State private var recentlyPlayedSongs: [LibrarySong] = []
  @State private var mostPlayedSongs: [(song: LibrarySong, count: Int)] = []
  @State private var radioMixes: [RadioStation] = []
  @State private var isLoading = true
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var hasLoadedInitialData = false

  private var recentlyAdded: [LibrarySong] {
    Array(library.songs.prefix(10))
  }

  @State private var rediscoverSongs: [LibrarySong] = []

  /// Tracks the user clearly liked — played often, hearted, or rated highly —
  /// that they haven't heard in a couple of months.
  private func computeRediscover() -> [LibrarySong] {
    let stats = historyTracker.statisticsBySongId()
    let cutoff = Date().addingTimeInterval(-60 * 24 * 60 * 60)

    let candidates = library.songs.compactMap { song -> (LibrarySong, Date)? in
      guard let stat = stats[song.id], !stat.isDisliked else { return nil }
      // Needs a last-played date: a song never played isn't "rediscovery",
      // it belongs in a discovery shelf instead.
      guard let lastPlayed = stat.lastPlayedAt, lastPlayed < cutoff else { return nil }

      let wasLoved = stat.isLiked || (stat.userRating ?? 0) >= 4 || stat.playCount >= 5
      guard wasLoved else { return nil }
      return (song, lastPlayed)
    }

    // Longest-forgotten first, capped so one artist can't fill the shelf.
    var seenArtists: [String: Int] = [:]
    return
      candidates
      .sorted { $0.1 < $1.1 }
      .filter { song, _ in
        let count = seenArtists[song.artist, default: 0]
        guard count < 2 else { return false }
        seenArtists[song.artist] = count + 1
        return true
      }
      .prefix(10)
      .map(\.0)
  }

  private var indexingMessage: String? {
    switch library.indexingStatus {
    case .indexing(let message):
      return message
    case .fetchingMetadata(let current, let total):
      if total > 1 {
        return "Fetching metadata (\(current + 1)/\(total))…"
      } else {
        return "Fetching metadata…"
      }
    case .complete, .idle:
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

          // Radio Mixes section
          if !radioMixes.isEmpty {
            RadioMixesSection(mixes: radioMixes)
          }

          if !genreRecommendations.isEmpty {
            GenrePicksSection(recommendations: genreRecommendations)
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

          // Music the user loved but hasn't returned to in a while. Every
          // other shelf here surfaces either what's new or what's already in
          // rotation; this is the only one that reaches back.
          if !rediscoverSongs.isEmpty {
            HorizontalSongSection(
              title: "Rediscover",
              songs: rediscoverSongs,
              onSongPlayed: refreshHomeSections
            )
          }
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
        genreRecommendations =
          recommendationEngine.genreRecommendations
      }
    }
    .refreshable {
      await loadData(forceRefresh: true)
    }
    .onChange(of: library.libraryVersion) {
      print(
        "[DEBUG] HomeView.onChange(libraryVersion) - Updating recommendations"
      )
      refreshHomeSections()
      Task {
        await recommendationEngine.generateAllRecommendations(forceRefresh: true)
        forYouRecommendations =
          recommendationEngine.forYouRecommendations
        genreRecommendations =
          recommendationEngine.genreRecommendations
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .songsWereDeleted)) { notification in
      guard let ids = notification.object as? Set<UUID> else { return }
      let albumIDs = notification.userInfo?["albumIDs"] as? Set<UUID> ?? []
      removeDeletedContentImmediately(songIDs: ids, albumIDs: albumIDs)
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
    ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
          Circle()
            .fill(themeManager.accentColor.opacity(0.22))
            .frame(width: 140, height: 140)
            .blur(radius: 18)
            .offset(x: 28, y: -20)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .stroke(.white.opacity(0.08), lineWidth: 1)
        }

      VStack(alignment: .leading, spacing: 8) {
        Text(greeting)
          .font(.system(size: 30, weight: .bold, design: .rounded))

        Text(headerSummary)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(24)
    }
    .frame(maxWidth: .infinity, minHeight: 164, alignment: .bottomLeading)
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

  private var headerSummary: String {
    if library.songs.isEmpty {
      return
        "Import your library to unlock personalized discovery, smart search, and offline playback."
    }

    let recentCount = recentlyPlayedSongs.count
    if recentCount > 0 {
      return
        "\(library.songs.count) songs ready. \(recentCount) recent favorites are shaping your recommendations."
    }

    return "\(library.songs.count) songs ready for smarter discovery."
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
        .background(themeManager.accentColor)
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
      RadioMixGenerator.shared.setModelContext(modelContext)

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
      genreRecommendations = recommendationEngine.genreRecommendations
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
    radioMixes = RadioMixGenerator.shared.fetchOrCreateMixes()
    rediscoverSongs = computeRediscover()
  }

  /// The deletion notification is posted before SwiftData detaches the song,
  /// letting every cached Home shelf drop it safely in the same run-loop turn.
  /// The library-version handler above then rebuilds recommendations from the
  /// surviving library.
  private func removeDeletedContentImmediately(
    songIDs: Set<UUID>,
    albumIDs: Set<UUID>
  ) {
    recentlyPlayedSongs.removeAll { songIDs.contains($0.id) }
    mostPlayedSongs.removeAll { songIDs.contains($0.song.id) }
    rediscoverSongs.removeAll { songIDs.contains($0.id) }
    forYouRecommendations.removeAll { recommendation in
      switch recommendation.item {
      case .song(let song): return songIDs.contains(song.id)
      case .album(let album): return albumIDs.contains(album.id)
      default: return false
      }
    }
    genreRecommendations.removeAll { recommendation in
      switch recommendation.item {
      case .song(let song): return songIDs.contains(song.id)
      case .album(let album): return albumIDs.contains(album.id)
      default: return false
      }
    }
    refreshHomeSections()
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
          .font(.system(size: 24, weight: .bold, design: .rounded))

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
  }
}

// MARK: - Song Card

struct SongCard: View {
  let song: LibrarySong
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AlbumArtworkView(artworkPath: song.effectiveArtworkPath, size: 140)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 140, alignment: .leading)
    }
    .padding(4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(song.title), \(song.artist)")
    .accessibilityHint("Plays this song")
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
      Text("Made For You")
        .font(.system(size: 24, weight: .bold, design: .rounded))
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
          AlbumArtworkView(artworkPath: song.effectiveArtworkPath, size: 160)
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
          .font(.system(size: 15, weight: .semibold))
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
    .padding(4)
  }
}

// MARK: - Radio Mixes Section

struct RadioMixesSection: View {
  let mixes: [RadioStation]
  @Environment(ThemeManager.self) private var themeManager
  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Radio for You")
          .font(.system(size: 24, weight: .bold, design: .rounded))
        Spacer()
      }
      .padding(.horizontal, 20)

      Text("Personalized stations based on your listening")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, -6)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(mixes) { mix in
            NavigationLink {
              RadioStationView(station: mix)
            } label: {
              RadioMixCard(mix: mix)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .padding(.vertical, 8)
  }
}

// MARK: - Radio Mix Card

struct RadioMixCard: View {
  let mix: RadioStation
  @Environment(ThemeManager.self) private var themeManager

  private let cardSize: CGFloat = 160

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RadioArtworkCollage(artworkPaths: mix.artworkPaths, colors: mix.colors, size: cardSize)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(mix.name)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
          .foregroundStyle(.primary)

        Text(mix.subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .frame(width: cardSize, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(mix.name). \(mix.subtitle)")
    .accessibilityHint("Opens this radio station")
  }
}

// MARK: - Genre picks (Home)

struct GenrePicksSection: View {
  let recommendations: [Recommendation]
  @Environment(ThemeManager.self) private var themeManager
  private let library = SongLibrary.shared

  private var genreRows: [(display: String, key: String)] {
    var seen = Set<String>()
    var out: [(String, String)] = []
    for r in recommendations {
      if case .basedOnGenre(let g) = r.reason {
        let key = g.lowercased()
        if !seen.contains(key) {
          seen.insert(key)
          out.append((g, key))
        }
      }
    }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Genre picks for you")
        .font(.title2.weight(.bold))
        .padding(.horizontal, 20)

      Text("Based on what you play")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, -6)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 14) {
          ForEach(genreRows, id: \.key) { row in
            NavigationLink {
              GenreSongsView(genre: row.display)
            } label: {
              genreTile(title: row.display)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .padding(.vertical, 8)
  }

  private func genreTile(title: String) -> some View {
    let artworkSongs = topSongs(for: title)
    return ZStack(alignment: .bottomLeading) {
      if let artworkPath = artworkSongs.first?.effectiveArtworkPath {
        ArtworkImage(artworkPath: artworkPath, size: 168, cornerRadius: 0)
          .frame(width: 168, height: 112)
          .clipped()
      } else {
        LinearGradient(
          colors: [.gray.opacity(0.35), .gray.opacity(0.12)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      LinearGradient(
        colors: [
          themeManager.accentColor.opacity(0.88),
          themeManager.accentColor.opacity(0.42),
          themeManager.accentColor.opacity(0.08),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      LinearGradient(
        colors: [.black.opacity(0.02), .black.opacity(0.72)],
        startPoint: .top,
        endPoint: .bottom
      )
      Text(title)
        .font(.title3.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .padding(14)
    }
    .frame(width: 168, height: 112)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    .accessibilityLabel("\(title), genre")
    .accessibilityHint("View songs in this genre")
  }

  /// Prefer artwork from the user's own library. Ranking by rating and play
  /// history gives each genre the album art that feels most representative,
  /// without requiring a network request or MusicKit authorization.
  private func topSongs(for genre: String) -> [LibrarySong] {
    let needle = genre.lowercased()
    let stats = ListeningHistoryTracker.shared.statisticsBySongId()
    return library.songs
      .filter { song in
        guard let songGenre = song.genre?.lowercased(), !songGenre.isEmpty else {
          return false
        }
        let parts = songGenre
          .components(separatedBy: CharacterSet(charactersIn: "/;,"))
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.contains(needle) || songGenre.contains(needle)
      }
      .sorted { lhs, rhs in
        let lhsStats = stats[lhs.id]
        let rhsStats = stats[rhs.id]
        let lhsScore = Double(lhsStats?.userRating ?? 0) * 100
          + Double(lhsStats?.playCount ?? 0)
        let rhsScore = Double(rhsStats?.userRating ?? 0) * 100
          + Double(rhsStats?.playCount ?? 0)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return (lhs.effectiveArtworkPath != nil) && (rhs.effectiveArtworkPath == nil)
      }
      .prefix(4)
      .map { $0 }
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
        .font(.system(size: 24, weight: .bold, design: .rounded))
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
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 42, height: 42)
          .background(color.gradient)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(16)
    }
    .buttonStyle(.plain)
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
    let parts = g.components(separatedBy: CharacterSet(charactersIn: "/;,"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    return parts.contains(needle) || g.lowercased().contains(needle)
  }

  var body: some View {
    List {
      if !songs.isEmpty {
        Section {
          actionButtons
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
        .listRowSeparator(.hidden)
      }

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

  /// Mirrors AlbumView's header actions so a genre behaves like any other
  /// collection in the app.
  private var actionButtons: some View {
    HStack(spacing: 16) {
      Button {
        // Explicitly off: shuffle is sticky across sessions, so tapping "Play"
        // after a shuffled queue would otherwise still play in random order.
        playback.shuffleMode = .off
        playback.playQueue(songs, startingAt: 0, from: .library)
      } label: {
        HStack {
          Image(systemName: "play.fill")
          Text("Play")
        }
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(themeManager.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: themeManager.accentColor.opacity(0.3), radius: 5, y: 3)
      }

      Button {
        playback.shuffleMode = .on
        playback.playQueue(
          songs,
          startingAt: Int.random(in: 0..<songs.count),
          from: .library
        )
      } label: {
        HStack {
          Image(systemName: "shuffle")
          Text("Shuffle")
        }
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(themeManager.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
      }
    }
    .buttonStyle(.borderless)
  }
}

#Preview {
  NavigationStack {
    HomeView()
  }
}
