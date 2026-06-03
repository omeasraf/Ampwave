//
//  ArtistView.swift
//  Ampwave
//
//  Enhanced artist detail view with header, biography, popular songs, albums, and related artists.
//

import SwiftData
internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct ArtistView: View {
  let artist: Artist
  @Environment(ThemeManager.self) private var themeManager
  @State private var viewModel: ArtistDetailViewModel

  init(artist: Artist) {
    self.artist = artist
    self._viewModel = State(initialValue: ArtistDetailViewModel(artist: artist))
  }

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        artistHeader

        if viewModel.isLoading {
          ProgressView()
            .padding(.vertical, 40)
        } else {
          content
        }
      }
    }
    .background(themeManager.backgroundColor)
    .navigationTitle(artist.name)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      toolbarContent
    }
    .task {
      await viewModel.loadData()
    }
  }

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 0) {
      actionButtons
        .padding(.horizontal, 20)
        .padding(.vertical, 16)

      if hasArtistInfo {
        ArtistInfoSection(artist: artist)
      } else {
        noInfoView
      }

      if !viewModel.topSongs.isEmpty {
        SectionHeader(title: "Popular")
        topSongsList
      }

      if !viewModel.albums.isEmpty {
        SectionHeader(title: "Albums")
        albumsGrid
      }

      if !viewModel.relatedArtists.isEmpty {
        SectionHeader(title: "Similar Artists")
        relatedArtistsGrid
      }

      if viewModel.songs.count > viewModel.topSongs.count {
        SectionHeader(title: "All Songs")
        allSongsList
      }

      // Padding for mini player
      Spacer().frame(height: 100)
    }
  }

  private var artistHeader: some View {
    VStack(spacing: 16) {
      ArtistImageView(artworkPath: artist.artworkPath, size: 180)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .padding(.top, 60)

      VStack(spacing: 4) {
        Text(artist.name)
          .font(.system(size: 32, weight: .bold))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 20)

        if let genres = artist.genresDisplay {
          Text(genres)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
      }

      HStack(spacing: 32) {
        StatView(value: "\(viewModel.songs.count)", label: "Songs")
        StatView(value: "\(viewModel.albums.count)", label: "Albums")
        if let totalPlays = calculateTotalPlays() {
          StatView(value: "\(totalPlays)", label: "Plays")
        }
      }
      .padding(.bottom, 40)
    }
    .frame(maxWidth: .infinity)
    .background {
      ZStack {
        // Background Image
        Group {
          if let fanartPath = artist.fanartPath, let url = PathManager.resolve(fanartPath) {
            #if os(iOS)
              if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
              }
            #else
              if let image = NSImage(contentsOfFile: url.path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
              }
            #endif
          } else if let fanart = artist.fanartURL, let url = URL(string: fanart) {
            AsyncImage(url: url) { phase in
              if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
              } else {
                Color.gray.opacity(0.1)
              }
            }
          } else {
            // Fallback to blurred artwork or gray
            Color.gray.opacity(0.1)
          }
        }

        // Blur and Gradient overlays
        Rectangle()
          .fill(.ultraThinMaterial)
          .opacity(0.8)

        LinearGradient(
          colors: [.clear, themeManager.backgroundColor],
          startPoint: .center,
          endPoint: .bottom
        )
      }
      .ignoresSafeArea(edges: .top)
    }
  }

  private var actionButtons: some View {
    HStack(spacing: 16) {
      Button {
        if !viewModel.songs.isEmpty {
          playback.shuffleMode = .on
          playback.playQueue(viewModel.songs.shuffled())
        }
      } label: {
        HStack {
          Image(systemName: "shuffle")
          Text("Shuffle")
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(themeManager.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }

      Button {
        if !viewModel.songs.isEmpty {
          playback.playQueue(viewModel.songs)
        }
      } label: {
        Image(systemName: "play.fill")
          .font(.system(size: 18))
          .frame(width: 54, height: 54)
          .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private var topSongsList: some View {
    VStack(spacing: 0) {
      ForEach(Array(viewModel.topSongs.enumerated()), id: \.element.id) { index, song in
        NumberedSongRow(
          number: index + 1,
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(
            viewModel.songs,
            startingAt: viewModel.songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        }
        .swipeActions(edge: .trailing) {
          Button {
            playlistManager.toggleLike(song: song)
          } label: {
            Image(systemName: playlistManager.isLiked(song: song) ? "heart.slash" : "heart")
          }
          .tint(themeManager.accentColor)
        }
      }
    }
    .padding(.horizontal, 20)
  }

  private var albumsGrid: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 16) {
        ForEach(viewModel.albums) { album in
          // AlbumCard already wraps a NavigationLink; adding artworkSize + frame
          // prevents the card from collapsing or expanding to fill the scroll width.
          AlbumCard(album: album, artworkSize: 160)
            .frame(width: 160)
        }
      }
      .padding(.horizontal, 20)
    }
  }

  private var relatedArtistsGrid: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 16) {
        ForEach(viewModel.relatedArtists) { relatedArtist in
          NavigationLink(destination: ArtistView(artist: relatedArtist)) {
            VStack(spacing: 10) {
              ArtistImageView(artworkPath: relatedArtist.artworkPath, size: 120)

              Text(relatedArtist.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(width: 120)
            }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 20)
    }
  }

  private var allSongsList: some View {
    VStack(spacing: 0) {
      ForEach(viewModel.songs) { song in
        SongRow(
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(
            viewModel.songs,
            startingAt: viewModel.songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        }
      }
    }
    .padding(.horizontal, 20)
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button {
          Task { await viewModel.refreshMetadata() }
        } label: {
          Label("Refresh Metadata", systemImage: "arrow.clockwise")
        }

        Button {
          // Add all to playlist logic
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        ShareLink(item: artist.name, subject: Text("Check out \(artist.name) on Ampwave"))
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 18))
      }
    }
  }

  private func calculateTotalPlays() -> Int? {
    let tracker = ListeningHistoryTracker.shared
    let total = viewModel.songs.reduce(0) { sum, song in
      sum + (tracker.getStatistics(for: song)?.playCount ?? 0)
    }
    return total > 0 ? total : nil
  }

  private var hasArtistInfo: Bool {
    (artist.cachedBiography != nil && !artist.cachedBiography!.isEmpty)
      || (artist.biography != nil && !artist.biography!.isEmpty)
      || (artist.origin != nil && !artist.origin!.isEmpty)
      || (artist.activeYears != nil && !artist.activeYears!.isEmpty)
  }

  private var noInfoView: some View {
    VStack(spacing: 8) {
      Text("No biography available")
        .font(.system(size: 15))
        .foregroundStyle(.secondary)

      Button {
        Task { await viewModel.refreshMetadata() }
      } label: {
        Text("Fetch Information")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(themeManager.accentColor)
      }
    }
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Artist Info Section

struct ArtistInfoSection: View {
  let artist: Artist
  @State private var isExpanded = false
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionHeader(title: "About")

      VStack(alignment: .leading, spacing: 12) {
        if let origin = artist.cachedOrigin ?? artist.origin, !origin.isEmpty {
          InfoRow(label: "Origin", value: origin)
        }

        if let activeYears = artist.cachedActiveYears ?? artist.activeYears, !activeYears.isEmpty {
          InfoRow(label: "Active", value: activeYears)
        }

        if let biography = artist.cachedBiography ?? artist.biography, !biography.isEmpty {
          Text(biography)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? nil : 4)
            .padding(.top, 4)

          if !isExpanded {
            Button("Read More") {
              withAnimation(.spring()) {
                isExpanded.toggle()
              }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(themeManager.accentColor)
          }
        }
      }
      .padding(.horizontal, 20)
    }
    .padding(.bottom, 8)
  }
}

struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.primary)
        .frame(width: 60, alignment: .leading)

      Text(value)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  NavigationStack {
    ArtistView(artist: Artist(name: "Sample Artist"))
  }
}

// MARK: - View Model

@MainActor
@Observable
class ArtistDetailViewModel {
  let artist: Artist
  private let library: SongLibrary
  private let metadataService: MetadataService

  var songs: [LibrarySong] = []
  var albums: [Album] = []
  var topSongs: [LibrarySong] = []
  var relatedArtists: [Artist] = []
  var isLoading = false
  var isRefreshing = false

  init(artist: Artist, library: SongLibrary = .shared, metadataService: MetadataService = .shared) {
    self.artist = artist
    self.library = library
    self.metadataService = metadataService
  }

  func loadData() async {
    isLoading = true
    defer { isLoading = false }

    // Get all songs by this artist (including featured)
    songs = library.getSongs(byArtist: artist.name)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    // Get all albums by this artist
    let normalizedArtistName = artist.name.lowercased()
    albums = library.albums.filter {
      ($0.artist ?? "").lowercased() == normalizedArtistName
    }.sorted {
      ($0.year ?? 0) > ($1.year ?? 0)
    }

    // Get top songs (by play count)
    let tracker = ListeningHistoryTracker.shared
    topSongs = songs.sorted {
      let plays1 = tracker.getStatistics(for: $0)?.playCount ?? 0
      let plays2 = tracker.getStatistics(for: $1)?.playCount ?? 0
      return plays1 > plays2
    }
    topSongs = Array(topSongs.prefix(5))

    // Find related artists based on genre similarity
    await findRelatedArtists()

    // If genres are missing, try to fetch them
    if artist.genres == nil || artist.genres?.isEmpty == true {
      await refreshMetadata()
    }
  }

  func refreshMetadata() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    if let metadata = await metadataService.fetchMetadata(for: artist) {
      artist.genres = metadata.genres
      artist.biography = metadata.biography
      artist.origin = metadata.origin
      artist.activeYears = metadata.activeYears
      artist.fanartURL = metadata.fanartURL?.absoluteString
      artist.musicBrainzId = metadata.musicBrainzId

      // Cache text data
      artist.cachedBiography = metadata.biography
      artist.cachedOrigin = metadata.origin
      artist.cachedActiveYears = metadata.activeYears
      artist.cachedGenres = metadata.genres

      if let artworkURL = metadata.artworkURL {
        if let path = await metadataService.downloadArtwork(from: artworkURL) {
          artist.artworkPath = path
          artist.isDedicatedArtwork = true
        }
      }

      if let fanartURL = metadata.fanartURL {
        if let path = await metadataService.downloadArtwork(from: fanartURL) {
          artist.fanartPath = path
        }
      }

      artist.lastUpdatedDate = Date()
      try? artist.modelContext?.save()
    }
  }

  private func findRelatedArtists() async {
    guard let artistGenres = artist.genres, !artistGenres.isEmpty else { return }

    let allArtists = await library.allArtists()
    let genreSet = Set(artistGenres.map { $0.lowercased() })

    relatedArtists = allArtists.filter { otherArtist in
      guard otherArtist.id != artist.id else { return false }
      guard let otherGenres = otherArtist.genres, !otherGenres.isEmpty else { return false }

      // Check for genre overlap
      let otherGenreSet = Set(otherGenres.map { $0.lowercased() })
      let commonGenres = genreSet.intersection(otherGenreSet)
      return !commonGenres.isEmpty
    }
    .sorted { $0.songCount > $1.songCount }
    .prefix(6)
    .map { $0 }
  }
}

// MARK: - Helper Views

struct SectionHeader: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(.system(size: 22, weight: .bold))
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 12)
  }
}

struct StatView: View {
  let value: String
  let label: String

  var body: some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.system(size: 18, weight: .bold))
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}
