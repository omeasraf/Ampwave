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
                                    ) ? "heart.slash" : "heart"
                                )
                            }
                            .tint(.pink)

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
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                }
            }
        }
    }

    private var albumHeader: some View {
        VStack(spacing: 16) {
            AlbumArtworkView(
                artworkPath: album.artworkPath,
                size: 200,
                icon: nil
            )

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)

                if let artist = album.artist {
                    Text(artist)
                        .font(.system(size: 18))
                        .foregroundStyle(.pink)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.pink)
                .clipShape(Capsule())
            }

            Button {
                playback.shuffleMode = .on
                playback.playAlbum(album)
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
        }
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
