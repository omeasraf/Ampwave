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

/// The configurable content sections on artist pages. The order is stored in
/// UserDefaults so it applies to every artist and does not require a data-model
/// migration.
enum ArtistDetailSection: String, CaseIterable, Identifiable {
  case about
  case albums
  case popular
  case similarArtists
  case allSongs

  static let orderKey = "com.ampwave.artistDetail.sectionOrder.v1"

  static let defaultOrder: [ArtistDetailSection] = [
    .about,
    .albums,
    .popular,
    .similarArtists,
    .allSongs,
  ]

  static var defaultOrderRaw: String {
    encode(defaultOrder)
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .about: return "About"
    case .albums: return "Albums"
    case .popular: return "Popular"
    case .similarArtists: return "Similar Artists"
    case .allSongs: return "All Songs"
    }
  }

  var systemImage: String {
    switch self {
    case .about: return "person.text.rectangle"
    case .albums: return "square.stack"
    case .popular: return "chart.bar.fill"
    case .similarArtists: return "person.2"
    case .allSongs: return "music.note.list"
    }
  }

  static func decode(_ raw: String) -> [ArtistDetailSection] {
    let saved = raw.split(separator: ",").compactMap {
      ArtistDetailSection(rawValue: String($0))
    }
    var result: [ArtistDetailSection] = []

    // Repair malformed or older saved layouts and append any sections added
    // by future versions without disturbing the user's existing order.
    for section in saved + defaultOrder where !result.contains(section) {
      result.append(section)
    }
    return result
  }

  static func encode(_ sections: [ArtistDetailSection]) -> String {
    sections.map(\.rawValue).joined(separator: ",")
  }
}

struct ArtistView: View {
  let artist: Artist
  @Environment(ThemeManager.self) private var themeManager
  @State private var viewModel: ArtistDetailViewModel
  @State private var showingSectionOrderEditor = false
  @AppStorage(ArtistDetailSection.orderKey) private var sectionOrderRaw =
    ArtistDetailSection.defaultOrderRaw
  @AppStorage(LibraryArtworkShape.storageKey) private var artworkShapeRaw =
    LibraryArtworkShape.roundedRectangle.rawValue

  init(artist: Artist) {
    self.artist = artist
    self._viewModel = State(initialValue: ArtistDetailViewModel(artist: artist))
  }

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }
  private var artworkShape: LibraryArtworkShape {
    LibraryArtworkShape(rawValue: artworkShapeRaw) ?? .roundedRectangle
  }

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
    .sheet(isPresented: $showingSectionOrderEditor) {
      ArtistSectionOrderEditor(sections: sectionOrderBinding)
    }
    .task {
      await viewModel.loadData()
    }
    // `libraryVersion` bumps on any add/delete. Without this the cached song
    // and album arrays go stale — deleting an album from here left it on
    // screen until the user navigated away and back.
    .task(id: library.libraryVersion) {
      guard !viewModel.isLoading else { return }
      await viewModel.reloadLocalContent()
    }
  }

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 0) {
      actionButtons
        .padding(.horizontal, 20)
        .padding(.vertical, 16)

      ForEach(ArtistDetailSection.decode(sectionOrderRaw)) { section in
        artistSection(section)
      }
    }
    // The tab accessory supplies its own scroll inset, including its current
    // expanded/collapsed height. Only add ordinary spacing after the content.
    .padding(.bottom, 24)
  }

  private var sectionOrderBinding: Binding<[ArtistDetailSection]> {
    Binding(
      get: { ArtistDetailSection.decode(sectionOrderRaw) },
      set: { sectionOrderRaw = ArtistDetailSection.encode($0) }
    )
  }

  @ViewBuilder
  private func artistSection(_ section: ArtistDetailSection) -> some View {
    switch section {
    case .about:
      if hasArtistInfo {
        ArtistInfoSection(artist: artist)
      } else {
        noInfoView
      }
    case .albums:
      if !viewModel.albums.isEmpty {
        SectionHeader(title: section.title)
        albumsGrid
      }
    case .popular:
      if !viewModel.topSongs.isEmpty {
        SectionHeader(title: section.title)
        topSongsList
      }
    case .similarArtists:
      if !viewModel.relatedArtists.isEmpty {
        SectionHeader(title: section.title)
        relatedArtistsGrid
      }
    case .allSongs:
      if viewModel.songs.count > viewModel.topSongs.count {
        SectionHeader(title: section.title)
        allSongsList
      }
    }
  }

  private var artistHeader: some View {
    VStack(spacing: 16) {
      ArtistImageView(
        artworkPath: artist.artworkPath,
        size: 180,
        shape: artworkShape
      )
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
          isCurrent: playback.currentItem?.id == song.id,
          artworkShape: artworkShape
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(
            viewModel.songs,
            startingAt: viewModel.songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        }
        .swipeActions(edge: .trailing) {
          Button {
            _ = playlistManager.toggleLike(song: song)
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
          AlbumCard(album: album, artworkSize: 160, artworkShape: artworkShape)
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
              ArtistImageView(
                artworkPath: relatedArtist.artworkPath,
                size: 120,
                shape: artworkShape
              )

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
    // This list lives inside the page's outer ScrollView, so a regular VStack
    // eagerly creates every SongRow. Large artists could consequently start
    // hundreds of artwork decodes in one render pass and exhaust the process.
    LazyVStack(spacing: 0) {
      ForEach(viewModel.songs) { song in
        SongRow(
          song: song,
          isCurrent: playback.currentItem?.id == song.id,
          artworkShape: artworkShape
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
          showingSectionOrderEditor = true
        } label: {
          Label("Edit Section Order", systemImage: "arrow.up.arrow.down")
        }

        Divider()

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
    let stats = ListeningHistoryTracker.shared.statisticsBySongId()
    let total = viewModel.songs.reduce(0) { sum, song in
      sum + (stats[song.id]?.playCount ?? 0)
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

private struct ArtistSectionOrderEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @Binding var sections: [ArtistDetailSection]

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
          }
          .onMove { source, destination in
            sections.move(fromOffsets: source, toOffset: destination)
          }
        } footer: {
          Text("Drag sections into the order you want. This layout applies to every artist.")
        }

        Section {
          Button("Restore Default Order") {
            sections = ArtistDetailSection.defaultOrder
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(themeManager.backgroundColor)
      .navigationTitle("Artist Sections")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

// MARK: - Artist Info Section

struct ArtistInfoSection: View {
  let artist: Artist

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
          ExpandableDescriptionView(text: biography)
            .padding(.top, 4)
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

  init(
    artist: Artist,
    library: SongLibrary? = nil,
    metadataService: MetadataService? = nil
  ) {
    self.artist = artist
    self.library = library ?? .shared
    self.metadataService = metadataService ?? .shared
  }

  /// Re-reads this artist's content from the library.
  ///
  /// Split out from `loadData()` so the view can refresh cheaply whenever the
  /// library changes — deleting an album used to leave it on screen until the
  /// user navigated away and back, because these arrays are snapshots and
  /// nothing re-took them. Deliberately does no network work, so re-running it
  /// on every library change can't trigger repeated metadata fetches.
  func reloadLocalContent() async {
    // Get all songs by this artist (including featured)
    songs = library.getSongs(byArtist: artist.name)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    // Get all albums by this artist
    let normalizedArtistName = artist.name.lowercased()
    albums = library.albums.filter {
      ArtistParser.parseArtists(from: $0.artist ?? "")
        .contains { $0.lowercased() == normalizedArtistName }
    }.sorted {
      ($0.year ?? 0) > ($1.year ?? 0)
    }

    // Get top songs (by play count). Stats are resolved once up front — looking
    // them up inside the comparator meant a database round trip per comparison.
    let stats = ListeningHistoryTracker.shared.statisticsBySongId()
    topSongs = Array(
      songs
        .sorted { (stats[$0.id]?.playCount ?? 0) > (stats[$1.id]?.playCount ?? 0) }
        .prefix(5)
    )

    // Find related artists based on genre similarity
    await findRelatedArtists()
  }

  func loadData() async {
    isLoading = true
    await reloadLocalContent()
    isLoading = false

    guard !Task.isCancelled else { return }

    // Fetch when genres are missing, or when the artist still has no photo of
    // their own — `artworkPath` may just be borrowed album art, which leaves
    // the header looking like an album cover rather than an artist portrait.
    // Do not keep the local library UI behind this optional network work.
    let needsGenres = artist.genres == nil || artist.genres?.isEmpty == true
    let needsArtwork = !artist.isDedicatedArtwork
    if needsGenres || needsArtwork {
      await refreshMetadata()
    }
  }

  func refreshMetadata() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    if let metadata = await metadataService.fetchMetadata(for: artist) {
      if let genres = metadata.genres, !genres.isEmpty { artist.genres = genres }
      if let biography = metadata.biography, !biography.isEmpty { artist.biography = biography }
      if let origin = metadata.origin, !origin.isEmpty { artist.origin = origin }
      if let activeYears = metadata.activeYears, !activeYears.isEmpty { artist.activeYears = activeYears }
      if let fanartURL = metadata.fanartURL { artist.fanartURL = fanartURL.absoluteString }
      if let musicBrainzId = metadata.musicBrainzId { artist.musicBrainzId = musicBrainzId }
      if let appleMusicId = metadata.appleMusicId { artist.appleMusicId = appleMusicId }

      // Cache text data
      if let biography = metadata.biography, !biography.isEmpty { artist.cachedBiography = biography }
      if let origin = metadata.origin, !origin.isEmpty { artist.cachedOrigin = origin }
      if let activeYears = metadata.activeYears, !activeYears.isEmpty { artist.cachedActiveYears = activeYears }
      if let genres = metadata.genres, !genres.isEmpty { artist.cachedGenres = genres }

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
