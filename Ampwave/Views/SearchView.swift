//
//  SearchView.swift
//  Ampwave
//
//  Modernized search with debounced queries, smarter ranking, and lighter rendering.
//

internal import SwiftUI

struct SearchView: View {
  @Environment(ThemeManager.self) private var themeManager
  @State private var searchText = ""
  @State private var debouncedQuery = ""
  @State private var selectedFilter: SearchFilter = .all
  @State private var recentSearches = SearchPersistence.loadRecentSearches()
  @State private var debounceTask: Task<Void, Never>?

  enum SearchFilter: String, CaseIterable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
  }

  private var isDebouncing: Bool {
    !searchText.isEmpty && searchText != debouncedQuery
  }

  var body: some View {
    VStack(spacing: 0) {
      if !searchText.isEmpty {
        filterPicker
      }

      if searchText.isEmpty {
        SearchEmptyState(
          recentSearches: recentSearches,
          onSelectRecent: selectRecentSearch,
          onClearRecent: clearRecentSearches
        )
      } else {
        ZStack(alignment: .top) {
          SearchResultsView(
            query: debouncedQuery,
            filter: selectedFilter
          )

          if isDebouncing {
            ProgressView()
              .controlSize(.small)
              .padding(.top, 12)
          }
        }
      }
    }
    .background(themeManager.backgroundColor)
    .navigationTitle("Search")
    .searchable(
      text: $searchText,
      placement: platformSearchPlacement,
      prompt: "Songs, artists, albums, lyrics..."
    )
    .onChange(of: searchText) { _, newValue in
      scheduleDebouncedSearch(for: newValue)
    }
    .onSubmit(of: .search) {
      persistSearchIfNeeded(searchText)
    }
  }

  private var platformSearchPlacement: SearchFieldPlacement {
    #if os(iOS)
      return .navigationBarDrawer(displayMode: .always)
    #else
      return .toolbar
    #endif
  }

  private var filterPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(SearchFilter.allCases, id: \.self) { filter in
          FilterChip(
            title: filter.rawValue,
            isSelected: selectedFilter == filter
          ) {
            withAnimation(.snappy(duration: 0.2)) {
              selectedFilter = filter
            }
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }

  private func scheduleDebouncedSearch(for value: String) {
    debounceTask?.cancel()

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      debouncedQuery = ""
      return
    }

    debounceTask = Task {
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      debouncedQuery = trimmed
      persistSearchIfNeeded(trimmed)
    }
  }

  private func persistSearchIfNeeded(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return }
    recentSearches = SearchPersistence.saveRecentSearch(trimmed)
  }

  private func selectRecentSearch(_ value: String) {
    searchText = value
    debouncedQuery = value
  }

  private func clearRecentSearches() {
    recentSearches = []
    SearchPersistence.clear()
  }
}

struct FilterChip: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void
  @Environment(ThemeManager.self) private var themeManager

  private var chipFillStyle: AnyShapeStyle {
    if isSelected {
      return AnyShapeStyle(.ultraThinMaterial)
    } else {
      return AnyShapeStyle(themeManager.cardBackgroundColor.opacity(0.72))
    }
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
          Capsule()
            .fill(chipFillStyle)
            .overlay {
              Capsule()
                .stroke(
                  isSelected ? themeManager.accentColor.opacity(0.35) : .white.opacity(0.08),
                  lineWidth: 1
                )
            }
        }
    }
    .buttonStyle(.plain)
  }
}

struct SearchEmptyState: View {
  let recentSearches: [String]
  let onSelectRecent: (String) -> Void
  let onClearRecent: () -> Void
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SearchHeroCard()
          .padding(.horizontal, 20)

        if !recentSearches.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Recent Searches")
                .font(.title3.weight(.semibold))

              Spacer()

              Button("Clear", action: onClearRecent)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(themeManager.accentColor)
            }

            FlowLayout(spacing: 8) {
              ForEach(recentSearches, id: \.self) { search in
                RecentSearchChip(search: search) {
                  onSelectRecent(search)
                }
              }
            }
          }
          .padding(.horizontal, 20)
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Browse")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 20)

          LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
          ) {
            BrowseCategoryCard(
              title: "Songs",
              subtitle: "Every track",
              color: themeManager.accentColor,
              libraryTab: .songs
            )
            BrowseCategoryCard(
              title: "Albums",
              subtitle: "Artwork first",
              color: .orange,
              libraryTab: .albums
            )
            BrowseCategoryCard(
              title: "Artists",
              subtitle: "By vibe",
              color: .green,
              libraryTab: .artists
            )
            BrowseCategoryCard(
              title: "Playlists",
              subtitle: "Your collections",
              color: .blue,
              isPlaylists: true
            )
          }
          .padding(.horizontal, 20)
        }
      }
      .padding(.vertical, 20)
    }
    .background(themeManager.backgroundColor)
  }
}

private struct SearchHeroCard: View {
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
          Circle()
            .fill(.white.opacity(0.18))
            .frame(width: 120, height: 120)
            .blur(radius: 20)
            .offset(x: 24, y: -26)
        }

      VStack(alignment: .leading, spacing: 10) {
        Text("Find the right track faster")
          .font(.system(size: 28, weight: .bold, design: .rounded))

        Text("Results now rank title, artist, album, and lyrics with smarter matching.")
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
      }
      .padding(22)
    }
    .frame(height: 164)
  }
}

struct RecentSearchChip: View {
  let search: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 12))
        Text(search)
          .font(.system(size: 14, weight: .medium))
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
  }
}

struct BrowseCategoryCard: View {
  let title: String
  let subtitle: String
  let color: Color
  var libraryTab: LibraryView.LibraryTab = .songs
  var isPlaylists = false

  var body: some View {
    NavigationLink(destination: destination) {
      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(
            LinearGradient(
              colors: [color.opacity(0.95), color.opacity(0.45)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 20, weight: .bold))
          Text(subtitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.82))
        }
        .foregroundStyle(.white)
        .padding(16)
      }
      .frame(height: 118)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var destination: some View {
    if isPlaylists {
      PlaylistsListView()
    } else {
      LibraryView(initialTab: libraryTab)
    }
  }
}

struct SearchResultsView: View {
  let query: String
  let filter: SearchView.SearchFilter
  @Environment(ThemeManager.self) private var themeManager
  @State private var results = SearchResultsBundle.empty

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    List {
      switch filter {
      case .all:
        allResultsSection
      case .songs:
        songsSection(results.songs)
      case .albums:
        albumsSection(results.albums)
      case .artists:
        artistsSection(results.artists)
      case .playlists:
        playlistsSection(results.playlists)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .task(id: searchID) {
      await refreshResults()
    }
  }

  private var searchID: String {
    "\(query.lowercased())|\(filter.rawValue)|\(library.songs.count)|\(library.albums.count)|\(playlistManager.playlists.count)"
  }

  private var allResultsSection: some View {
    Group {
      if let topSong = results.topSong {
        Section {
          TopResultCard(song: topSong, query: query)
        } header: {
          Text("Top Result")
            .font(.title3.weight(.semibold))
        }
        .listRowBackground(themeManager.backgroundColor)
      }

      if !results.songs.isEmpty {
        songsSection(Array(results.songs.prefix(8)))
      }

      if !results.albums.isEmpty {
        albumsSection(Array(results.albums.prefix(6)))
      }

      if !results.artists.isEmpty {
        artistsSection(Array(results.artists.prefix(6)))
      }

      if !results.playlists.isEmpty {
        playlistsSection(Array(results.playlists.prefix(6)))
      }

      if results.isEmpty {
        Section {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("Try a song title, artist, album, or lyric phrase.")
          )
        }
        .listRowBackground(themeManager.backgroundColor)
      }
    }
  }

  private func songsSection(_ songs: [LibrarySong]) -> some View {
    Section {
      ForEach(songs) { song in
        SongRow(song: song, isCurrent: false)
          .contentShape(Rectangle())
          .onTapGesture {
            PlaybackController.shared.play(song, from: .search)
          }
          .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
          .listRowBackground(themeManager.backgroundColor)
      }
    } header: {
      Text("Songs")
        .font(.title3.weight(.semibold))
    }
  }

  private func albumsSection(_ albums: [Album]) -> some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(albums) { album in
            AlbumCard(album: album)
          }
        }
        .padding(.horizontal, 20)
      }
      .listRowInsets(EdgeInsets())
      .listRowBackground(themeManager.backgroundColor)
    } header: {
      Text("Albums")
        .font(.title3.weight(.semibold))
    }
  }

  private func artistsSection(_ artists: [Artist]) -> some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(artists) { artist in
            NavigationLink(destination: ArtistView(artist: artist)) {
              VStack(spacing: 10) {
                ArtistImageView(artworkPath: artist.artworkPath, size: 110)

                Text(artist.name)
                  .font(.system(size: 14, weight: .semibold))
                  .lineLimit(1)
              }
              .frame(width: 112)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
      }
      .listRowInsets(EdgeInsets())
      .listRowBackground(themeManager.backgroundColor)
    } header: {
      Text("Artists")
        .font(.title3.weight(.semibold))
    }
  }

  private func playlistsSection(_ playlists: [Playlist]) -> some View {
    Section {
      ForEach(playlists) { playlist in
        NavigationLink(destination: PlaylistView(playlist: playlist)) {
          HStack(spacing: 14) {
            PlaylistArtworkView(playlist: playlist, size: 56)

            VStack(alignment: .leading, spacing: 4) {
              Text(playlist.name)
                .font(.system(size: 16, weight: .semibold))
              Text("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
          }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(themeManager.backgroundColor)
      }
    } header: {
      Text("Playlists")
        .font(.title3.weight(.semibold))
    }
  }

  private func refreshResults() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      results = .empty
      return
    }

    await Task.yield()
    results = buildResults(for: trimmed)
  }

  private func buildResults(for query: String) -> SearchResultsBundle {
    let normalizedQuery = normalize(query)
    let songRanks = rankedSongs(for: normalizedQuery)
    let albumRanks = rankedAlbums(for: normalizedQuery)
    let artistRanks = rankedArtists(for: normalizedQuery)
    let playlistRanks = rankedPlaylists(for: normalizedQuery)

    return SearchResultsBundle(
      songs: songRanks.map(\.item),
      albums: albumRanks.map(\.item),
      artists: artistRanks.map(\.item),
      playlists: playlistRanks.map(\.item),
      topSong: songRanks.first?.item
    )
  }

  private func rankedSongs(for normalizedQuery: String) -> [Ranked<LibrarySong>] {
    library.songs.compactMap { song in
      let titleScore = matchScore(haystack: normalize(song.title), needle: normalizedQuery, weight: 4.0)
      let artistScore = matchScore(haystack: normalize(song.artist), needle: normalizedQuery, weight: 3.0)
      let albumScore = matchScore(haystack: normalize(song.album ?? ""), needle: normalizedQuery, weight: 2.0)
      let genreScore = matchScore(haystack: normalize(song.genre ?? ""), needle: normalizedQuery, weight: 1.2)

      var score = titleScore + artistScore + albumScore + genreScore

      if normalizedQuery.count >= 3, score < 4.5 {
        if normalize(song.lyrics ?? "").contains(normalizedQuery) {
          score += 1.4
        } else if normalizedQuery.count >= 4,
          let syncedLyrics = LyricsService.shared.getCachedLyrics(for: song),
          syncedLyrics.lines.contains(where: { normalize($0.text).contains(normalizedQuery) })
        {
          score += 1.0
        }
      }

      if score <= 0 { return nil }
      if song.artworkPath != nil { score += 0.2 }
      if song.genre != nil { score += 0.1 }

      return Ranked(item: song, score: score)
    }
    .sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
      }
      return lhs.score > rhs.score
    }
  }

  private func rankedAlbums(for normalizedQuery: String) -> [Ranked<Album>] {
    library.albums.compactMap { album in
      let score =
        matchScore(haystack: normalize(album.name), needle: normalizedQuery, weight: 3.5)
        + matchScore(haystack: normalize(album.artist ?? ""), needle: normalizedQuery, weight: 2.2)

      guard score > 0 else { return nil }
      return Ranked(item: album, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  private func rankedArtists(for normalizedQuery: String) -> [Ranked<Artist>] {
    let artists = library.artists.isEmpty
      ? Array(Set(library.songs.map(\.artist))).map { Artist(name: $0) }
      : library.artists

    return artists.compactMap { artist in
      let score = matchScore(haystack: normalize(artist.name), needle: normalizedQuery, weight: 3.2)
      guard score > 0 else { return nil }
      return Ranked(item: artist, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  private func rankedPlaylists(for normalizedQuery: String) -> [Ranked<Playlist>] {
    playlistManager.playlists.compactMap { playlist in
      let score = matchScore(haystack: normalize(playlist.name), needle: normalizedQuery, weight: 3.0)
      guard score > 0 else { return nil }
      return Ranked(item: playlist, score: score)
    }
    .sorted { $0.score > $1.score }
  }

  private func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(
        of: "[^a-z0-9 ]",
        with: " ",
        options: .regularExpression
      )
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func matchScore(haystack: String, needle: String, weight: Double) -> Double {
    guard !haystack.isEmpty, !needle.isEmpty else { return 0 }
    if haystack == needle { return weight * 1.2 }
    if haystack.hasPrefix(needle) { return weight }
    if haystack.contains(needle) { return weight * 0.75 }

    let haystackTokens = Set(haystack.split(separator: " ").map(String.init))
    let needleTokens = needle.split(separator: " ").map(String.init)
    let overlap = needleTokens.filter(haystackTokens.contains).count
    guard overlap > 0 else { return 0 }
    return weight * (Double(overlap) / Double(max(needleTokens.count, 1))) * 0.65
  }
}

struct TopResultCard: View {
  let song: LibrarySong
  let query: String
  @Environment(ThemeManager.self) private var themeManager

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    Button {
      playback.play(song, from: .search)
    } label: {
      HStack(spacing: 16) {
        AlbumArtworkView(artworkPath: song.artworkPath, size: 86)

        VStack(alignment: .leading, spacing: 6) {
          Text(song.title)
            .font(.system(size: 20, weight: .bold))
            .lineLimit(1)

          Text(song.artist)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            Label("Best match", systemImage: "sparkles")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(themeManager.accentColor)

            if let album = song.album, !album.isEmpty {
              Text(album)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }

        Spacer()

        Image(systemName: "play.circle.fill")
          .font(.system(size: 42))
          .foregroundStyle(themeManager.accentColor)
      }
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(.white.opacity(0.08), lineWidth: 1)
          }
      )
    }
    .buttonStyle(.plain)
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
    return result.size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
    for (index, subview) in subviews.enumerated() {
      subview.place(
        at: CGPoint(
          x: bounds.minX + result.positions[index].x,
          y: bounds.minY + result.positions[index].y
        ),
        proposal: .unspecified
      )
    }
  }

  struct FlowResult {
    var size: CGSize = .zero
    var positions: [CGPoint] = []

    init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
      var x: CGFloat = 0
      var y: CGFloat = 0
      var rowHeight: CGFloat = 0

      for subview in subviews {
        let size = subview.sizeThatFits(.unspecified)

        if x + size.width > maxWidth && x > 0 {
          x = 0
          y += rowHeight + spacing
          rowHeight = 0
        }

        positions.append(CGPoint(x: x, y: y))
        rowHeight = max(rowHeight, size.height)
        x += size.width + spacing
      }

      self.size = CGSize(width: maxWidth, height: y + rowHeight)
    }
  }
}

private struct SearchResultsBundle {
  let songs: [LibrarySong]
  let albums: [Album]
  let artists: [Artist]
  let playlists: [Playlist]
  let topSong: LibrarySong?

  var isEmpty: Bool {
    songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
  }

  static let empty = SearchResultsBundle(
    songs: [],
    albums: [],
    artists: [],
    playlists: [],
    topSong: nil
  )
}

private struct Ranked<Item> {
  let item: Item
  let score: Double
}

private enum SearchPersistence {
  private static let key = "com.ampwave.recentSearches"

  static func loadRecentSearches() -> [String] {
    (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
  }

  static func saveRecentSearch(_ value: String) -> [String] {
    var items = loadRecentSearches().filter { $0.caseInsensitiveCompare(value) != .orderedSame }
    items.insert(value, at: 0)
    let trimmed = Array(items.prefix(8))
    UserDefaults.standard.set(trimmed, forKey: key)
    return trimmed
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }
}
