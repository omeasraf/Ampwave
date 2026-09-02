//
// LibraryView.swift
// Ampwave
//
// Library view with tabs for Songs, Albums, Artists, and Playlists.
//

import SwiftData
internal import SwiftUI

// MARK: - Optimized Search Helpers

/// Optimized fuzzy search with early exit for common cases
private func optimizedFuzzyMatch(_ pattern: String, _ text: String, maxDistance: Int = 2) -> Bool {
  let p = pattern.lowercased()
  let t = text.lowercased()

  if p.isEmpty { return true }

  // Quick win: direct substring match (much faster than Levenshtein)
  if t.contains(p) { return true }

  // For very short patterns, use faster character-by-character check
  if p.count <= 3 {
    return fuzzyMatchShort(p, t, maxDistance: maxDistance)
  }

  // For longer patterns, use optimized Levenshtein with early termination
  return optimizedLevenshteinDistance(p, t, maxDistance: maxDistance)
}

/// Fast fuzzy matching for short strings
private func fuzzyMatchShort(_ pattern: String, _ text: String, maxDistance: Int) -> Bool {
  let patternChars = Array(pattern)
  let textChars = Array(text)
  let patternLength = patternChars.count
  let textLength = textChars.count

  // If text is much shorter than pattern, can't match
  if textLength < patternLength - maxDistance {
    return false
  }

  var matches = 0
  var i = 0
  var j = 0
  var mismatches = 0

  while i < patternLength && j < textLength && mismatches <= maxDistance {
    if patternChars[i] == textChars[j] {
      matches += 1
      i += 1
      j += 1
    } else {
      mismatches += 1
      // Try skipping character in text
      j += 1
    }
  }

  let remainingPattern = patternLength - i
  return remainingPattern <= maxDistance
}

/// Optimized Levenshtein with early termination
private func optimizedLevenshteinDistance(_ a: String, _ b: String, maxDistance: Int) -> Bool {
  let aChars = Array(a)
  let bChars = Array(b)
  let aLen = aChars.count
  let bLen = bChars.count

  // Quick bounds check
  if abs(aLen - bLen) > maxDistance {
    return false
  }

  // Use only two rows for memory efficiency
  var previousRow = Array(0...aLen)

  for j in 1...bLen {
    var currentRow = [j]
    var minInRow = j

    for i in 1...aLen {
      let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
      let insertion = currentRow[i - 1] + 1
      let deletion = previousRow[i] + 1
      let substitution = previousRow[i - 1] + cost
      let cellValue = min(insertion, deletion, substitution)
      currentRow.append(cellValue)
      minInRow = min(minInRow, cellValue)
    }

    // Early termination if minimum distance already exceeds max
    if minInRow > maxDistance {
      return false
    }

    previousRow = currentRow
  }

  return previousRow[aLen] <= maxDistance
}

// MARK: - GridSizePicker

/// Apple Music–style inline segmented icon control for grid density.
struct GridSizePicker: View {
  @Binding var selection: String
  let options: [(id: String, icon: String)]

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.id) { option in
        Button {
          HapticManager.shared.select()
          withAnimation(.easeInOut(duration: 0.15)) { selection = option.id }
        } label: {
          Image(systemName: option.icon)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 26)
            .foregroundStyle(selection == option.id ? themeManager.accentColor : .secondary)
            .background(
              selection == option.id
                ? themeManager.accentColor.opacity(0.12)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .frame(height: 32)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .fixedSize(horizontal: true, vertical: true)
  }
}

// MARK: - Library grid density

/// Grid density shared by the Albums and Artists tabs.
///
/// Both tabs previously offered different options (Albums had three sizes,
/// Artists two, with mismatched icons), so the same control meant different
/// things depending on the tab. One enum owns the columns, gutters and cell
/// width for both so the tabs stay in step.
enum LibraryGridSize: String, CaseIterable {
  case small
  case medium
  case large

  var columnCount: Int {
    switch self {
    case .small: return 3
    case .medium: return 2
    case .large: return 1
    }
  }

  /// Gutter between cells. Denser grids get tighter gutters so the artwork —
  /// not the whitespace — keeps most of the row.
  var spacing: CGFloat {
    switch self {
    case .small: return 10
    case .medium: return 16
    case .large: return 20
    }
  }

  var horizontalPadding: CGFloat {
    self == .small ? 16 : 20
  }

  var icon: String {
    switch self {
    case .small: return "square.grid.3x3.fill"
    case .medium: return "square.grid.2x2.fill"
    case .large: return "rectangle.fill"
    }
  }

  static var pickerOptions: [(id: String, icon: String)] {
    allCases.map { (id: $0.rawValue, icon: $0.icon) }
  }

  var gridColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
      count: columnCount
    )
  }

  /// Row gap is slightly wider than the column gap: the caption text under each
  /// cell already reads as vertical space, so matching gaps look cramped.
  var rowSpacing: CGFloat { spacing + 6 }

  /// Exact cell width for a container of `width`. The cards take a fixed width
  /// rather than `maxWidth: .infinity`, so handing them the measured value is
  /// what keeps artwork square and captions aligned with the artwork edge.
  func cellWidth(in width: CGFloat) -> CGFloat {
    let usable = width - horizontalPadding * 2 - spacing * CGFloat(columnCount - 1)
    return max(60, (usable / CGFloat(columnCount)).rounded(.down))
  }
}

// MARK: - LibrarySortMenu

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
        .dateAddedDescending, .dateAddedAscending, .yearDescending, .yearAscending,
        .ratingDescending, .ratingAscending, .random,
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

// MARK: - Genres grid

struct GenresGridView: View {
  @Environment(ThemeManager.self) private var themeManager
  @AppStorage("com.ampwave.genreGridSize.v1") private var genreGridSizeRaw: String = "medium"
  @State private var gridWidth: CGFloat = 400
  private var library: SongLibrary { SongLibrary.shared }

  private var gridSize: LibraryGridSize {
    LibraryGridSize(rawValue: genreGridSizeRaw) ?? .medium
  }

  private var entries: [(name: String, count: Int)] {
    library.genreEntriesSortedByPopularity()
  }

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
          LazyVGrid(columns: gridSize.gridColumns, spacing: gridSize.rowSpacing) {
            ForEach(entries, id: \.name) { entry in
              NavigationLink {
                GenreSongsView(genre: entry.name)
              } label: {
                genreCell(
                  name: entry.name,
                  count: entry.count,
                  width: gridSize.cellWidth(in: gridWidth)
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, gridSize.horizontalPadding)
          .padding(.top, 16)
          .padding(.bottom, 24)
        }
      }
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .onChange(of: geo.size.width, initial: true) { _, width in
            gridWidth = width
          }
      }
    }
    .background(themeManager.backgroundColor)
  }

  private func genreCell(name: String, count: Int, width: CGFloat) -> some View {
    let artworkPath = representativeArtworkPath(for: name)
    let compact = width < 120
    return GeometryReader { proxy in
      ZStack(alignment: .bottomLeading) {
        if let artworkPath {
          ArtworkImage(
            artworkPath: artworkPath,
            size: max(proxy.size.width, proxy.size.height),
            cornerRadius: 0
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
        } else {
          LinearGradient(
            colors: [.gray.opacity(0.35), .gray.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }

        // A restrained accent wash keeps the artwork recognizable while giving
        // the browse grid the cohesive, editorial look of Apple Music's cards.
        LinearGradient(
          colors: [
            themeManager.accentColor.opacity(0.88),
            themeManager.accentColor.opacity(0.42),
            themeManager.accentColor.opacity(0.08),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        // Bottom scrim for text legibility
        LinearGradient(
          colors: [.clear, .black.opacity(0.62)],
          startPoint: .center,
          endPoint: .bottom
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(name)
            .font(.system(size: compact ? 15 : 19, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
          Text("\(count) songs")
            .font(.system(size: compact ? 10 : 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
        }
        .padding(compact ? 10 : 14)
      }
    }
    .frame(width: width, height: width / 1.52)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(name), \(count) songs")
    .accessibilityHint("View songs in this genre")
  }

  private func representativeArtworkPath(for genre: String) -> String? {
    let needle = genre.lowercased()
    let stats = ListeningHistoryTracker.shared.statisticsBySongId()
    return library.songs
      .filter { song in
        guard let rawGenre = song.genre?.lowercased(), !rawGenre.isEmpty else {
          return false
        }
        let parts = rawGenre
          .components(separatedBy: CharacterSet(charactersIn: "/;,"))
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.contains(needle) || rawGenre.contains(needle)
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
      .compactMap(\.effectiveArtworkPath)
      .first
  }
}

// MARK: - LibraryView (updated)

struct LibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @State private var selectedTab: LibraryTab
  @AppStorage("com.ampwave.albumGridSize.v2") private var albumGridSizeRaw = "medium"
  @AppStorage("com.ampwave.artistGridSize.v2") private var artistGridSizeRaw = "medium"
  @AppStorage("com.ampwave.genreGridSize.v1") private var genreGridSizeRaw = "medium"

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
    TabView(selection: $selectedTab) {
      SongsListView()
        .tag(LibraryTab.songs)

      AlbumsGridView()
        .tag(LibraryTab.albums)

      ArtistsGridView()
        .tag(LibraryTab.artists)

      GenresGridView()
        .tag(LibraryTab.genres)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .safeAreaInset(edge: .top, spacing: 0) {
      libraryTabStrip
        .background(.bar)
        .overlay(alignment: .bottom) {
          Divider().opacity(0.35)
        }
    }
    .background(themeManager.backgroundColor)
    .tint(themeManager.accentColor)
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if selectedTab != .songs {
          GridSizePicker(
            selection: gridSizeBinding,
            options: LibraryGridSize.pickerOptions
          )
        }

        if selectedTab != .genres {
          LibrarySortMenu(selectedTab: selectedTab, appSettings: appSettings)
        }
      }
    }
    .onAppear {
      playlistManager.setModelContext(modelContext)
    }
  }

  private var gridSizeBinding: Binding<String> {
    switch selectedTab {
    case .albums: return $albumGridSizeRaw
    case .artists: return $artistGridSizeRaw
    case .genres: return $genreGridSizeRaw
    case .songs: return .constant("medium")
    }
  }

  private var libraryTabStrip: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(LibraryTab.allCases, id: \.self) { tab in
            Button {
              withAnimation(.snappy(duration: 0.25)) {
                selectedTab = tab
              }
            } label: {
              HStack(spacing: 10) {
                Image(systemName: tab.icon)
                  .font(.system(size: 16, weight: .semibold))
                Text(tab.rawValue)
                  .font(.system(size: 15, weight: .semibold, design: .rounded))
              }
              .foregroundStyle(selectedTab == tab ? .white : .primary)
              .padding(.vertical, 10)
              .padding(.horizontal, 16)
              .background(
                selectedTab == tab
                  ? AnyShapeStyle(themeManager.accentColor.gradient)
                  : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
              )
              .glassEffect(
                .identity,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
              )
            }
            .buttonStyle(.plain)
            .id(tab)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
      }
      .onChange(of: selectedTab, initial: true) { _, tab in
        withAnimation(.snappy(duration: 0.25)) {
          proxy.scrollTo(tab, anchor: .center)
        }
      }
    }
  }
}

// MARK: - Albums Grid View

struct AlbumsGridView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  // Key is versioned: the stored values now mean different column counts than the
  // pre-shared-layout build, so old selections shouldn't carry over.
  @AppStorage("com.ampwave.albumGridSize.v2") private var albumGridSizeRaw: String = "medium"
  /// Tracks the ScrollView's available width so exact column widths can be handed to
  /// AlbumCard (a GeometryReader inside LazyVGrid causes layout issues).
  @State private var gridWidth: CGFloat = 400

  private var gridSize: LibraryGridSize {
    LibraryGridSize(rawValue: albumGridSizeRaw) ?? .medium
  }

  private var library: SongLibrary { SongLibrary.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  var filteredAlbums: [Album] {
    sortAlbums(library.albums)
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
    case .ratingDescending:
      return albums.sorted { albumRating($0) > albumRating($1) }
    case .ratingAscending:
      return albums.sorted { albumRating($0) < albumRating($1) }
    }
  }

  private func albumRating(_ album: Album) -> Double {
    let ratings = album.songs.compactMap { ListeningHistoryTracker.shared.rating(for: $0) }
    guard !ratings.isEmpty else { return 0 }
    return Double(ratings.reduce(0, +)) / Double(ratings.count)
  }

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
        LazyVGrid(columns: gridSize.gridColumns, spacing: gridSize.rowSpacing) {
          ForEach(filteredAlbums) { album in
            AlbumCard(album: album, artworkSize: gridSize.cellWidth(in: gridWidth))
          }
        }
        .padding(.horizontal, gridSize.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 24)
      }
    }
    // Capture available width for the large full-bleed column calculation
    .background {
      GeometryReader { geo in
        Color.clear
          .onChange(of: geo.size.width, initial: true) { _, w in gridWidth = w }
      }
    }
    .background(themeManager.backgroundColor)
  }
}

// MARK: - Artists Grid View

struct ArtistsGridView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @State private var artists: [Artist] = []
  @AppStorage("com.ampwave.artistGridSize.v2") private var artistGridSizeRaw: String = "medium"
  /// Same measurement trick as AlbumsGridView — cards take a fixed width, so the
  /// container width has to be measured outside the grid.
  @State private var gridWidth: CGFloat = 400

  private var library: SongLibrary { SongLibrary.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  private var gridSize: LibraryGridSize {
    LibraryGridSize(rawValue: artistGridSizeRaw) ?? .medium
  }

  var filteredArtists: [Artist] {
    sortArtists(artists)
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
    ScrollView {
      if artists.isEmpty {
        ContentUnavailableView(
          "No Artists",
          systemImage: "person.2",
          description: Text("Import songs to see artists")
        )
        .padding(.top, 100)
      } else if filteredArtists.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass",
          description: Text("No artists match your search")
        )
        .padding(.top, 100)
      } else {
        LazyVGrid(columns: gridSize.gridColumns, spacing: gridSize.rowSpacing) {
          ForEach(filteredArtists) { artist in
            ArtistCard(artist: artist, artworkSize: gridSize.cellWidth(in: gridWidth))
          }
        }
        .padding(.horizontal, gridSize.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 24)
      }
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .onChange(of: geo.size.width, initial: true) { _, w in gridWidth = w }
      }
    }
    .background(themeManager.backgroundColor)
    .task(id: library.libraryVersion) {
      await loadArtists()
    }
  }

  private func loadArtists() async {
    artists = await library.allArtists()
  }
}

// MARK: - Helper Extension

extension String {
  func split(separators: CharacterSet) -> [String] {
    return self.components(separatedBy: separators).filter { !$0.isEmpty }
  }
}

#Preview {
  LibraryView()
}
