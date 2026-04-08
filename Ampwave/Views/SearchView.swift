//
//  SearchView.swift
//  Ampwave
//
//  Enhanced search view for local library with filters and results.
//

internal import SwiftUI

struct SearchView: View {
  @State private var searchText: String = ""
  @State private var selectedFilter: SearchFilter = .all

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }

  enum SearchFilter: String, CaseIterable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !searchText.isEmpty {
          filterPicker
        }

        if searchText.isEmpty {
          SearchEmptyState()
        } else {
          SearchResultsView(
            searchText: searchText,
            filter: selectedFilter
          )
        }
      }
      .navigationTitle("Search")
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Songs, artists, albums..."
      )
    }
  }

  private var filterPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(SearchFilter.allCases, id: \.self) { filter in
          FilterChip(
            title: filter.rawValue,
            isSelected: selectedFilter == filter
          ) {
            selectedFilter = filter
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
    }
  }
}

// MARK: - Filter Chip

struct FilterChip: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.pink : Color.gray.opacity(0.2))
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Search Empty State

struct SearchEmptyState: View {
  @State private var recentSearches: [String] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if !recentSearches.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Recent Searches")
                .font(.system(size: 18, weight: .semibold))

              Spacer()

              Button("Clear") {
                recentSearches.removeAll()
              }
              .font(.system(size: 14))
              .foregroundStyle(.pink)
            }

            FlowLayout(spacing: 8) {
              ForEach(recentSearches, id: \.self) { search in
                RecentSearchChip(search: search) {}
              }
            }
          }
          .padding(.horizontal, 20)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("Browse All")
            .font(.system(size: 18, weight: .semibold))
            .padding(.horizontal, 20)

          LazyVGrid(
            columns: [
              GridItem(.flexible()),
              GridItem(.flexible()),
            ], spacing: 12
          ) {
            BrowseCategoryCard(title: "Songs", color: .red)
            BrowseCategoryCard(title: "Albums", color: .orange)
            BrowseCategoryCard(title: "Artists", color: .green)
            BrowseCategoryCard(title: "Playlists", color: .blue)
          }
          .padding(.horizontal, 20)
        }
      }
      .padding(.vertical, 20)
    }
  }
}

// MARK: - Recent Search Chip

struct RecentSearchChip: View {
  let search: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 12))
        Text(search)
          .font(.system(size: 14))
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.gray.opacity(0.15))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Browse Category Card

struct BrowseCategoryCard: View {
  let title: String
  let color: Color

  var body: some View {
    NavigationLink(destination: LibraryView()) {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(color)

        Text(title)
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(.white)
          .padding()
      }
      .frame(height: 100)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Search Results View

struct SearchResultsView: View {
  let searchText: String
  let filter: SearchView.SearchFilter

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var matchingSongs: [LibrarySong] {
    library.songs.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.artist.localizedCaseInsensitiveContains(searchText)
        || ($0.album?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
  }

  var matchingAlbums: [Album] {
    library.albums.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
  }

  var matchingArtists: [Artist] {
    let artistNames = Set(library.songs.map { $0.artist })
    return artistNames.filter {
      $0.localizedCaseInsensitiveContains(searchText)
    }.map { Artist(name: $0) }
  }

  var matchingPlaylists: [Playlist] {
    playlistManager.playlists.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    List {
      switch filter {
      case .all:
        allResultsSection
      case .songs:
        songsSection(matchingSongs)
      case .albums:
        albumsSection(matchingAlbums)
      case .artists:
        artistsSection(matchingArtists)
      case .playlists:
        playlistsSection(matchingPlaylists)
      }
    }
    .listStyle(.plain)
  }

  private var allResultsSection: some View {
    Group {
      if let topSong = matchingSongs.first {
        Section {
          TopResultCard(song: topSong)
        } header: {
          Text("Top Result")
            .font(.system(size: 18, weight: .semibold))
        }
      }

      if !matchingSongs.isEmpty {
        songsSection(Array(matchingSongs.prefix(5)))
      }

      if !matchingAlbums.isEmpty {
        albumsSection(Array(matchingAlbums.prefix(5)))
      }

      if !matchingArtists.isEmpty {
        artistsSection(Array(matchingArtists.prefix(5)))
      }

      if !matchingPlaylists.isEmpty {
        playlistsSection(Array(matchingPlaylists.prefix(5)))
      }

      if matchingSongs.isEmpty && matchingAlbums.isEmpty && matchingArtists.isEmpty
        && matchingPlaylists.isEmpty
      {
        Section {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("Try a different search term")
          )
        }
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
      }
    } header: {
      HStack {
        Text("Songs")
          .font(.system(size: 18, weight: .semibold))
        Spacer()
        if songs.count >= 5 && matchingSongs.count > 5 {
          NavigationLink("See All") {
            //                        SongsListView(songs: matchingSongs, title: "Songs")
          }
          .font(.system(size: 14))
        }
      }
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
    } header: {
      Text("Albums")
        .font(.system(size: 18, weight: .semibold))
    }
  }

  private func artistsSection(_ artists: [Artist]) -> some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(artists) { artist in
            NavigationLink(destination: ArtistView(artist: artist)) {
              VStack(spacing: 8) {
                ArtistImageView(artworkPath: artist.artworkPath, size: 100)

                Text(artist.name)
                  .font(.system(size: 14, weight: .medium))
                  .lineLimit(1)
              }
              .frame(width: 100)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
      }
    } header: {
      Text("Artists")
        .font(.system(size: 18, weight: .semibold))
    }
  }

  private func playlistsSection(_ playlists: [Playlist]) -> some View {
    Section {
      ForEach(playlists) { playlist in
        NavigationLink(destination: PlaylistView(playlist: playlist)) {
          HStack(spacing: 12) {
            AlbumArtworkView(artworkPath: playlist.artworkPath, size: 50, icon: nil)

            VStack(alignment: .leading, spacing: 2) {
              Text(playlist.name)
                .font(.system(size: 16, weight: .medium))
              Text("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    } header: {
      Text("Playlists")
        .font(.system(size: 18, weight: .semibold))
    }
  }
}

// MARK: - Top Result Card

struct TopResultCard: View {
  let song: LibrarySong

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    Button {
      playback.play(song, from: .search)
    } label: {
      HStack(spacing: 16) {
          AlbumArtworkView(artworkPath: song.artworkPath, size: 80, icon: nil)

        VStack(alignment: .leading, spacing: 4) {
          Text(song.title)
            .font(.system(size: 20, weight: .bold))
            .lineLimit(1)

          Text(song.artist)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            Label("Song", systemImage: "music.note")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Image(systemName: "play.circle.fill")
          .font(.system(size: 40))
          .foregroundStyle(.pink)
      }
      .padding()
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Flow Layout

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
          y: bounds.minY + result.positions[index].y),
        proposal: .unspecified)
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

#Preview {
  SearchView()
}
