//
//  SearchResultsView.swift
//  Ampwave
//
//  Created by Ome Asraf on 5/4/26.
//

import SwiftData
internal import SwiftUI

struct SearchResultsView: View {
  let query: String
  let filter: SearchView.SearchFilter
  let onResultTapped: () -> Void

  @Environment(ThemeManager.self) private var themeManager
  @State private var results = SearchResultsBundle.empty
  @State private var searchTask: Task<Void, Never>?

  private var searchManager = SearchManager.shared

  init(query: String, filter: SearchView.SearchFilter, onResultTapped: @escaping () -> Void) {
    self.query = query
    self.filter = filter
    self.onResultTapped = onResultTapped
  }

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
    .onChange(of: query) { _, _ in refreshResults() }
    .onChange(of: filter) { _, _ in refreshResults() }
    .onAppear { refreshResults() }
    .onDisappear { searchTask?.cancel() }
  }

  private var allResultsSection: some View {
    Group {
      if let topSong = results.topSong {
        Section {
          TopResultCard(song: topSong, query: query)
            .onTapGesture {
              onResultTapped()
              PlaybackController.shared.play(topSong, from: .search)
            }
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

      if results.isEmpty && !query.isEmpty {
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
            onResultTapped()
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
            AlbumCard(album: album, artworkSize: 160)
              .frame(width: 160)
              .onTapGesture {
                onResultTapped()
              }
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
            .simultaneousGesture(
              TapGesture().onEnded {
                onResultTapped()
              }
            )
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
        .simultaneousGesture(
          TapGesture().onEnded {
            onResultTapped()
          }
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(themeManager.backgroundColor)
      }
    } header: {
      Text("Playlists")
        .font(.title3.weight(.semibold))
    }
  }

  private func refreshResults() {
    searchTask?.cancel()

    guard !query.isEmpty else {
      results = .empty
      return
    }

    searchTask = Task {
      let computed = await searchManager.search(query: query, filter: filter)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        results = computed
      }
    }
  }
}
