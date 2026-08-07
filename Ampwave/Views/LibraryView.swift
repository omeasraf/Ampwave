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
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
  private var library: SongLibrary { SongLibrary.shared }

  private var entries: [(name: String, count: Int)] {
    library.genreEntriesSortedByPopularity()
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
    let icon = GenrePalette.icon(for: name)
    return ZStack(alignment: .bottomLeading) {
      // Main gradient
      LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

      // Specular highlight blob (top-right)
      Circle()
        .fill(Color.white.opacity(0.18))
        .frame(width: 100, height: 100)
        .blur(radius: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .offset(x: 24, y: -28)

      // Bottom scrim for text legibility
      LinearGradient(
        colors: [.clear, .black.opacity(0.55)],
        startPoint: .center,
        endPoint: .bottom
      )

      // Decorative genre icon (top-right, watermark style)
      Image(systemName: icon)
        .font(.system(size: 52, weight: .bold))
        .foregroundStyle(.white.opacity(0.16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 14)
        .padding(.top, 12)

      // Text
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.title2.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(3)
          .minimumScaleFactor(0.72)
        Text("\(count) songs")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white.opacity(0.9))
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, minHeight: 140)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    // Colored shadow — tinted with the genre's own palette color
    .shadow(color: (colors.first ?? .black).opacity(0.42), radius: 14, x: 0, y: 7)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(name), \(count) songs")
    .accessibilityHint("View songs in this genre")
  }
}

// MARK: - LibraryView (updated)

struct LibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @State private var selectedTab: LibraryTab

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
      libraryTabStrip

      Group {
        switch selectedTab {
        case .songs:
          SongsListView()
        case .albums:
          AlbumsGridView()
        case .artists:
          ArtistsGridView()
        case .genres:
          GenresGridView()
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
    .onAppear {
      playlistManager.setModelContext(modelContext)
    }
  }

  private var libraryTabStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(LibraryTab.allCases, id: \.self) { tab in
          Button {
            selectedTab = tab
          } label: {
            HStack(spacing: 10) {
              Image(systemName: tab.icon)
                .font(.system(size: 16, weight: .semibold))
              Text(tab.rawValue)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selectedTab == tab ? .white : .primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
              selectedTab == tab
                ? AnyShapeStyle(themeManager.accentColor.gradient)
                : AnyShapeStyle(.clear),
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .glassEffect(
              .identity,
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
    }
  }
}

// MARK: - Albums Grid View

struct AlbumsGridView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @AppStorage("com.ampwave.albumGridSize") private var albumGridSizeRaw: String = "large"
  /// Tracks the ScrollView's available width so the full-bleed large mode can pass exact column
  /// widths to AlbumCard (avoiding a GeometryReader inside LazyVGrid which causes layout issues).
  @State private var gridWidth: CGFloat = 400

  private var isLargeMode: Bool { albumGridSizeRaw == "large" }
  private var isSmallMode: Bool { albumGridSizeRaw == "small" }

  private var artworkSize: CGFloat {
    switch albumGridSizeRaw {
    case "small":  return 90
    case "medium": return 130
    default:       return (gridWidth - 2) / 2   // large: fills half the available width
    }
  }

  private var gridColumns: [GridItem] {
    switch albumGridSizeRaw {
    case "large":
      // 2 columns, 2 pt gap — full bleed, no outer padding
      return [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    case "small":
      // 3 columns
      return [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
      ]
    default:
      // medium — 2 columns with breathing room
      return [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }
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
        LazyVGrid(
          columns: gridColumns,
          spacing: isLargeMode ? 2 : (isSmallMode ? 8 : 18)
        ) {
          ForEach(filteredAlbums) { album in
            AlbumCard(album: album, artworkSize: artworkSize, isFullBleed: isLargeMode)
          }
        }
        .padding(.horizontal, isLargeMode ? 0 : 20)
        .padding(.top, isLargeMode ? 0 : 16)
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        GridSizePicker(
          selection: $albumGridSizeRaw,
          options: [
            (id: "small",  icon: "square.grid.3x3.fill"),
            (id: "medium", icon: "square.grid.2x2.fill"),
            (id: "large",  icon: "rectangle.fill"),
          ]
        )
      }
    }
  }
}

// MARK: - Artists Grid View

struct ArtistsGridView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query private var settings: [AppSettings]
  @State private var artists: [Artist] = []
  @AppStorage("com.ampwave.artistGridSize") private var artistGridSizeRaw: String = "large"

  private var library: SongLibrary { SongLibrary.shared }

  private var appSettings: AppSettings {
    settings.first ?? AppSettings.getOrCreate(in: modelContext)
  }

  private var artistArtworkSize: CGFloat {
    artistGridSizeRaw == "small" ? 90 : 150
  }

  private var gridColumns: [GridItem] {
    if artistGridSizeRaw == "small" {
      return [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
      ]
    }
    return [
      GridItem(.flexible(), spacing: 16),
      GridItem(.flexible(), spacing: 16),
    ]
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
        LazyVGrid(columns: gridColumns, spacing: artistGridSizeRaw == "small" ? 8 : 18) {
          ForEach(filteredArtists) { artist in
            ArtistCard(artist: artist, artworkSize: artistArtworkSize)
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
      }
    }
    .background(themeManager.backgroundColor)
    .task {
      await loadArtists()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        GridSizePicker(
          selection: $artistGridSizeRaw,
          options: [
            (id: "small", icon: "square.grid.3x3.fill"),
            (id: "large", icon: "square.grid.2x2.fill"),
          ]
        )
      }
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
