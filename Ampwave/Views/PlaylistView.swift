//
//  PlaylistView.swift
//  Ampwave
//
//  Playlist detail view with cover, title, description, and editable track list.
//

import PhotosUI
internal import SwiftUI

struct PlaylistView: View {
  let playlist: Playlist

  @State private var isEditing = false
  @State private var showingEditSheet = false
  @State private var showingAddSongsSheet = false
  @State private var showingDeleteConfirmation = false

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    List {
      Section {
        playlistHeader
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      if !playlist.songs.isEmpty {
        Section {
          ForEach(playlist.songs) { song in
            SongRow(
              song: song,
              isCurrent: playback.currentItem?.id == song.id
            )
            .contentShape(Rectangle())
            .onTapGesture {
              playback.playPlaylist(
                playlist,
                startingAt: playlist.songs.firstIndex(where: {
                  $0.id == song.id
                }) ?? 0
              )
            }
          }
          .onDelete(perform: deleteSongs)
          .onMove(perform: moveSongs)
        }
      } else {
        Section {
          ContentUnavailableView(
            "Empty Playlist",
            systemImage: "music.note.list",
            description: Text("Add songs to get started")
          )
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(playlist.name)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if playlist.playlistType != .likedSongs {
            Button {
              showingEditSheet = true
            } label: {
              Label("Edit Details", systemImage: "pencil")
            }
          }

          Button {
            showingAddSongsSheet = true
          } label: {
            Label("Add Songs", systemImage: "plus")
          }

          Button {
            isEditing.toggle()
          } label: {
            Label(
              isEditing ? "Done" : "Edit Order",
              systemImage: isEditing
                ? "checkmark" : "arrow.up.arrow.down"
            )
          }

          Divider()

          if playlist.playlistType != .likedSongs {
            Button {
              playlistManager.togglePin(playlist)
            } label: {
              Label(
                playlist.isPinned ? "Unpin" : "Pin",
                systemImage: playlist.isPinned
                  ? "pin.slash" : "pin"
              )
            }
          }

          Button {
            WatchSyncService.shared.updateSyncStatus(for: playlist, shouldSync: !playlist.shouldSyncToWatch)
          } label: {
            Label(
              playlist.shouldSyncToWatch ? "Remove from Watch" : "Sync to Watch",
              systemImage: playlist.shouldSyncToWatch ? "applewatch.slash" : "applewatch"
            )
          }

          if playlist.playlistType == .custom
            || playlist.playlistType == .smart
          {
            Divider()

            Button(role: .destructive) {
              showingDeleteConfirmation = true
            } label: {
              Label("Delete Playlist", systemImage: "trash")
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    .sheet(isPresented: $showingEditSheet) {
      EditPlaylistSheet(playlist: playlist)
    }
    .sheet(isPresented: $showingAddSongsSheet) {
      AddSongsToPlaylistSheet(playlist: playlist)
    }
    .alert("Delete Playlist?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        playlistManager.deletePlaylist(playlist)
      }
    } message: {
      Text("This action cannot be undone.")
    }
  }

  private var playlistHeader: some View {
    VStack(spacing: 20) {
      PlaylistArtworkView(
        playlist: playlist,
        size: 200
      )

      VStack(spacing: 8) {
        Text(playlist.name)
          .font(.system(size: 24, weight: .bold))
          .multilineTextAlignment(.center)

        if let description = playlist.playlistDescription {
          Text(description)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        HStack(spacing: 8) {
          Text(
            "\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")"
          )
          .font(.system(size: 14))
          .foregroundStyle(.secondary)

          if playlist.totalDuration > 0 {
            Text("•")
              .font(.system(size: 14))
              .foregroundStyle(.secondary)

            Text(formatDuration(playlist.totalDuration))
              .font(.system(size: 14))
              .foregroundStyle(.secondary)
          }
        }
      }

      if !playlist.songs.isEmpty {
        HStack(spacing: 16) {
          Button {
            playback.playPlaylist(playlist)
          } label: {
            HStack {
              Image(systemName: "play.fill")
              Text("Play")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(Color.pink)
            .clipShape(Capsule())
          }

          Button {
            playback.shuffleMode = .on
            let randomStartIndex = Int.random(
              in: 0..<playlist.songs.count
            )
            playback.playPlaylist(
              playlist,
              startingAt: randomStartIndex
            )
          } label: {
            HStack {
              Image(systemName: "shuffle")
              Text("Shuffle")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
          }
        }
      }
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }

  private func deleteSongs(at offsets: IndexSet) {
    playlistManager.removeSongs(at: offsets, from: playlist)
  }

  private func moveSongs(from source: IndexSet, to destination: Int) {
    playlistManager.moveSongs(in: playlist, from: source, to: destination)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let hours = Int(duration) / 3600
    let minutes = (Int(duration) % 3600) / 60

    if hours > 0 {
      return "\(hours) hr \(minutes) min"
    } else {
      return "\(minutes) min"
    }
  }
}

#Preview {
  NavigationStack {
    PlaylistView(playlist: Playlist(name: "My Playlist"))
  }
}
