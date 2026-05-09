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

  private var searchManager = SearchManager.shared

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
            filter: selectedFilter,
            onResultTapped: { persistSearchIfNeeded(debouncedQuery) }
          )

          if isDebouncing || searchManager.isIndexing {
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
    .onDisappear {
      debounceTask?.cancel()
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
      // 400ms debounce
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(.easeOut(duration: 0.15)) {
          debouncedQuery = trimmed
        }
      }
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
    // Bringing it to top
    persistSearchIfNeeded(value)
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
          .lineLimit(1)
          .frame(maxWidth: 160)
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

struct TopResultCard: View {
  let song: LibrarySong
  let query: String
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    HStack(spacing: 16) {
      AlbumArtworkView(artworkPath: song.effectiveArtworkPath, size: 86)

      VStack(alignment: .leading, spacing: 6) {
        Text(song.title)
          .font(.system(size: 20, weight: .bold))
          .lineLimit(1)

        Text(song.artist)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)

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

private enum SearchPersistence {
  private static let key = "com.ampwave.recentSearches"

  static func loadRecentSearches() -> [String] {
    (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
  }

  static func saveRecentSearch(_ value: String) -> [String] {
    var items = loadRecentSearches().filter { $0.caseInsensitiveCompare(value) != .orderedSame }
    items.insert(value, at: 0)
    let trimmed = Array(items.prefix(20))
    UserDefaults.standard.set(trimmed, forKey: key)
    return trimmed
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }
}
