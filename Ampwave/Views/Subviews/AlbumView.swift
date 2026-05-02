//
//  AlbumView.swift
//  Ampwave
//
//  Album detail view with artwork, track list, and actions.
//

internal import SwiftUI

struct AlbumView: View {
  let album: Album

  @State private var showingAddToPlaylist = false

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var sortedSongs: [LibrarySong] {
    album.songs.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
  }

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    List {
      Section {
        albumHeader
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      Section {
        actionButtons
      }
      .listRowBackground(Color.clear)

      if !sortedSongs.isEmpty {
        Section {
          ForEach(Array(sortedSongs.enumerated()), id: \.element.id) {
            index,
            song in
            NumberedSongRow(
              number: index + 1,
              song: song,
              isCurrent: playback.currentItem?.id == song.id
            )
            .contentShape(Rectangle())
            .onTapGesture {
              playback.playAlbum(album, startingAtTrack: index)
            }
            .swipeActions(edge: .trailing) {
              Button {
                playlistManager.toggleLike(song: song)
              } label: {
                Image(
                  systemName: playlistManager.isLiked(
                    song: song
                  ) ? "heart.fill" : "heart"
                )
              }
              .tint(themeManager.accentColor)

              Button {
                playback.playNext(song)
              } label: {
                Label("Play Next", systemImage: "text.insert")
              }
              .tint(.orange)
            }
          }
        } header: {
          Text("Tracks")
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle(album.name)
    .listStyle(platformListStyle)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            showingAddToPlaylist = true
          } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
          }

          Button {
            // Share album
          } label: {
            Label("Share", systemImage: "square.and.arrow.up")
          }

          Divider()

          Button {
            // Refresh metadata
          } label: {
            Label(
              "Refresh Metadata",
              systemImage: "arrow.clockwise"
            )
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(themeManager.accentColor)
        }
      }
    }
  }

  private var platformListStyle: some ListStyle {
    #if os(iOS)
      .insetGrouped
    #else
      .inset
    #endif
  }

  private var albumHeader: some View {
    VStack(spacing: 16) {
      AlbumArtworkView(
        artworkPath: album.artworkPath,
        size: 220
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

      VStack(spacing: 4) {
        Text(album.name)
          .font(.system(size: 28, weight: .bold))
          .multilineTextAlignment(.center)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(themeManager.accentColor)
        }

        HStack(spacing: 8) {
          if let year = album.year {
            Text("\(year)")
              .font(.system(size: 14))
              .foregroundStyle(.secondary)
          }

          Text("•")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)

          Text(
            "\(album.songCount) song\(album.songCount == 1 ? "" : "s")"
          )
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }

  private var actionButtons: some View {
    HStack(spacing: 16) {
      Button {
        playback.playAlbum(album)
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
        playback.playAlbum(album)
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
    .padding(.horizontal)
  }
}

#Preview {
  NavigationStack {
    AlbumView(
      album: Album(
        name: "Sample Album",
        artist: "Sample Artist",
        year: 2024
      )
    )
  }
}
