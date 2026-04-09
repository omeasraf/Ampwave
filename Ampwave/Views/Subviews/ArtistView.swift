//
//  ArtistView.swift
//  Ampwave
//
//  Artist detail view with header, top songs, albums, and related artists.
//

internal import SwiftUI

struct ArtistView: View {
  let artist: Artist

  @State private var songs: [LibrarySong] = []
  @State private var albums: [Album] = []
  @State private var topSongs: [LibrarySong] = []
  @State private var isLoading = true

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        artistHeader

        actionButtons
          .padding(.horizontal, 20)
          .padding(.vertical, 16)

        if !topSongs.isEmpty {
          SectionHeader(title: "Popular")
          topSongsList
        }

        if !albums.isEmpty {
          SectionHeader(title: "Albums")
          albumsGrid
        }

        if songs.count > topSongs.count {
          SectionHeader(title: "Songs")
          allSongsList
        }
      }
    }
    .navigationTitle(artist.name)
    .navigationBarTitleDisplayMode(.large)
    .task {
      await loadArtistData()
    }
  }

  private var artistHeader: some View {
    VStack(spacing: 16) {
      ArtistImageView(artworkPath: artist.artworkPath, size: 180)

      Text(artist.name)
        .font(.system(size: 28, weight: .bold))

      if let genres = artist.genresDisplay {
        Text(genres)
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        StatView(value: "\(songs.count)", label: "Songs")
        StatView(value: "\(albums.count)", label: "Albums")
        if let totalPlays = calculateTotalPlays() {
          StatView(value: "\(totalPlays)", label: "Plays")
        }
      }
    }
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity)
    .background(
      LinearGradient(
        colors: [.gray.opacity(0.15), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private var actionButtons: some View {
    HStack(spacing: 16) {
      Button {
        if !songs.isEmpty {
          playback.shuffleMode = .on
          playback.playQueue(songs.shuffled())
        }
      } label: {
        HStack {
          Image(systemName: "shuffle")
          Text("Shuffle")
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.pink)
        .clipShape(Capsule())
      }

      Button {
        // Show add to playlist sheet
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 18))
          .frame(width: 50, height: 44)
          .background(.ultraThinMaterial)
          .clipShape(Circle())
      }

      Menu {
        Button {
          // Refresh metadata
        } label: {
          Label("Refresh Metadata", systemImage: "arrow.clockwise")
        }

        Button {
          // Add all to playlist
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 18))
          .frame(width: 50, height: 44)
          .background(.ultraThinMaterial)
          .clipShape(Circle())
      }
    }
  }

  private var topSongsList: some View {
    VStack(spacing: 0) {
      ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
        NumberedSongRow(
          number: index + 1,
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(songs, startingAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        }
        .swipeActions(edge: .trailing) {
          Button {
            playlistManager.toggleLike(song: song)
          } label: {
            Image(systemName: playlistManager.isLiked(song: song) ? "heart.slash" : "heart")
          }
          .tint(.pink)
        }
      }
    }
    .padding(.horizontal, 20)
  }

  private var albumsGrid: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 16) {
        ForEach(albums) { album in
          AlbumCard(album: album)
        }
      }
      .padding(.horizontal, 20)
    }
  }

  private var allSongsList: some View {
    VStack(spacing: 0) {
      ForEach(songs) { song in
        SongRow(
          song: song,
          isCurrent: playback.currentItem?.id == song.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
          playback.playQueue(songs, startingAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        }
      }
    }
    .padding(.horizontal, 20)
  }

  private func loadArtistData() async {
    isLoading = true

    // Get all songs featuring this artist (including as a featured artist)
    songs = library.getSongs(byArtist: artist.name)
      .sorted { $0.title < $1.title }

    let normalizedArtistName = artist.name.lowercased()
    albums = library.albums.filter {
      ($0.artist ?? "").lowercased() == normalizedArtistName
    }.sorted {
      ($0.year ?? 0) > ($1.year ?? 0)
    }

    let tracker = ListeningHistoryTracker.shared
    let sortedByPlays = songs.sorted {
      let plays1 = tracker.getStatistics(for: $0)?.playCount ?? 0
      let plays2 = tracker.getStatistics(for: $1)?.playCount ?? 0
      return plays1 > plays2
    }
    topSongs = Array(sortedByPlays.prefix(5))

    isLoading = false
  }

  private func calculateTotalPlays() -> Int? {
    let tracker = ListeningHistoryTracker.shared
    let total = songs.reduce(0) { sum, song in
      sum + (tracker.getStatistics(for: song)?.playCount ?? 0)
    }
    return total > 0 ? total : nil
  }
}

// MARK: - Section Header

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

// MARK: - Stat View

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

#Preview {
  NavigationStack {
    ArtistView(artist: Artist(name: "Sample Artist"))
  }
}
