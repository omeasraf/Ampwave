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
  @State private var showingRulesSheet = false
  @State private var playlistJSONShareURL: URL?
  @State private var playlistM3UShareURL: URL?
  @Environment(ThemeManager.self) private var themeManager

  private var isSmartPlaylist: Bool { playlist.playlistType == .smart }

  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }

  private var playlistExportStamp: String {
    "\(playlist.id.uuidString)-\(playlist.songCount)"
  }

  var body: some View {
    List {
      Section {
        playlistHeader
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      songSection
    }
    .listStyle(platformListStyle)
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle(playlist.name)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          playlistMenuContent
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    #if os(iOS)
      .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    #endif
    .sheet(isPresented: $showingEditSheet) {
      EditPlaylistSheet(playlist: playlist)
    }
    .sheet(isPresented: $showingAddSongsSheet) {
      AddSongsToPlaylistSheet(playlist: playlist)
    }
    .sheet(isPresented: $showingRulesSheet) {
      SmartPlaylistRulesSheet(playlist: playlist)
    }
    .alert("Delete Playlist?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        playlistManager.deletePlaylist(playlist)
      }
    } message: {
      Text("This action cannot be undone.")
    }
    .task(id: playlistExportStamp) {
      guard !playlist.orderedSongs.isEmpty else {
        playlistJSONShareURL = nil
        playlistM3UShareURL = nil
        return
      }
      playlistJSONShareURL = try? PlaylistImportExport.writeJSONToTemp(
        playlist: playlist,
        library: library
      )
      playlistM3UShareURL = try? PlaylistImportExport.writeM3UToTemp(
        playlist: playlist,
        library: library
      )
    }
  }

  @ViewBuilder
  private var songSection: some View {
    if playlist.orderedSongs.isEmpty {
      emptySongsSection
    } else if isSmartPlaylist {
      smartSongListSection
    } else {
      editableSongListSection
    }
  }

  private var smartSongListSection: some View {
    Section {
      ForEach(playlist.orderedSongs) { song in
        SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
          .contentShape(Rectangle())
          .onTapGesture {
            let idx = playlist.orderedSongs.firstIndex(where: { $0.id == song.id }) ?? 0
            playback.playPlaylist(playlist, startingAt: idx)
          }
      }
    }
    .listRowBackground(themeManager.cardBackgroundColor)
  }

  private var editableSongListSection: some View {
    Section {
      ForEach(playlist.orderedSongs) { song in
        SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
          .contentShape(Rectangle())
          .onTapGesture {
            let idx = playlist.orderedSongs.firstIndex(where: { $0.id == song.id }) ?? 0
            playback.playPlaylist(playlist, startingAt: idx)
          }
      }
      .onDelete(perform: deleteSongs)
      .onMove(perform: moveSongs)
    }
    .listRowBackground(themeManager.cardBackgroundColor)
  }

  private var emptySongsSection: some View {
    Section {
      if isSmartPlaylist {
        ContentUnavailableView(
          "No Matching Songs",
          systemImage: "music.note.list",
          description: Text("Adjust your rules to find matching songs")
        )
      } else {
        ContentUnavailableView(
          "Empty Playlist",
          systemImage: "music.note.list",
          description: Text("Add songs to get started")
        )
      }
    }
    .listRowBackground(themeManager.cardBackgroundColor)
  }

  @ViewBuilder
  private var playlistMenuContent: some View {
    if isSmartPlaylist {
      Button { showingRulesSheet = true } label: {
        Label("Edit Rules", systemImage: "slider.horizontal.3")
      }
      Button { playlistManager.updateSmartPlaylist(playlist) } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      Button { showingEditSheet = true } label: {
        Label("Edit Name", systemImage: "pencil")
      }
    } else {
      if playlist.playlistType != .likedSongs {
        Button { showingEditSheet = true } label: {
          Label("Edit Details", systemImage: "pencil")
        }
      }
      Button { showingAddSongsSheet = true } label: {
        Label("Add Songs", systemImage: "plus")
      }
    }

    shareLinks

    if !isSmartPlaylist {
      Button {
        isEditing.toggle()
      } label: {
        Label(
          isEditing ? "Done" : "Edit Order",
          systemImage: isEditing ? "checkmark" : "arrow.up.arrow.down"
        )
      }
    }

    Divider()

    if playlist.playlistType != .likedSongs {
      Button { playlistManager.togglePin(playlist) } label: {
        Label(
          playlist.isPinned ? "Unpin" : "Pin",
          systemImage: playlist.isPinned ? "pin.slash" : "pin"
        )
      }
    }

    #if os(iOS)
      Button {
        WatchSyncService.shared.updateSyncStatus(
          for: playlist, shouldSync: !playlist.shouldSyncToWatch)
      } label: {
        Label(
          playlist.shouldSyncToWatch ? "Remove from Watch" : "Sync to Watch",
          systemImage: playlist.shouldSyncToWatch ? "applewatch.slash" : "applewatch"
        )
      }
    #endif

    if playlist.playlistType == .custom || playlist.playlistType == .smart {
      Divider()
      Button(role: .destructive) { showingDeleteConfirmation = true } label: {
        Label("Delete Playlist", systemImage: "trash")
      }
    }
  }

  @ViewBuilder
  private var shareLinks: some View {
    if !playlist.orderedSongs.isEmpty, let url = playlistJSONShareURL {
      ShareLink(
        item: url,
        subject: Text(playlist.name),
        message: Text(
          "Portable playlist export from Ampwave with stable track identifiers and metadata."
        ),
        preview: SharePreview(playlist.name, icon: Image(systemName: "music.note.list"))
      ) {
        Label("Share JSON Playlist…", systemImage: "square.and.arrow.up")
      }
    }
    if !playlist.orderedSongs.isEmpty, let url = playlistM3UShareURL {
      ShareLink(
        item: url,
        subject: Text(playlist.name),
        message: Text(
          "Extended M3U playlist from Ampwave with metadata-based track resolution."
        ),
        preview: SharePreview(playlist.name, icon: Image(systemName: "music.note.list"))
      ) {
        Label("Share M3U Playlist…", systemImage: "music.note.list")
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

      if !playlist.orderedSongs.isEmpty {
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
            .background(themeManager.accentColor)
            .clipShape(Capsule())
          }

          Button {
            playback.shuffleMode = .on
            let randomStartIndex = Int.random(
              in: 0..<playlist.orderedSongs.count
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
            .background(themeManager.cardBackgroundColor)
            .clipShape(Capsule())
            .overlay(
              Capsule()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
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

// MARK: - Radio Station View

struct RadioStationView: View {
  let station: RadioStation
  @Environment(ThemeManager.self) private var themeManager
  private var playback: PlaybackController { PlaybackController.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    List {
      Section {
        stationHeader
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      Section {
        ForEach(station.orderedSongs) { song in
          SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
            .contentShape(Rectangle())
            .onTapGesture {
              let idx = station.orderedSongs.firstIndex(where: { $0.id == song.id }) ?? 0
              playback.playQueue(station.orderedSongs, startingAt: idx, from: .radio)
            }
        }
      }
      .listRowBackground(themeManager.cardBackgroundColor)
    }
    .listStyle(platformListStyle)
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle(station.name)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            saveAsPlaylist()
          } label: {
            Label("Save as Playlist", systemImage: "plus.square.on.square")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
  }

  private var stationHeader: some View {
    VStack(spacing: 20) {
      RadioArtworkCollage(artworkPaths: station.artworkPaths, colors: station.colors, size: 200)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

      VStack(spacing: 8) {
        Text(station.name)
          .font(.system(size: 24, weight: .bold))
          .multilineTextAlignment(.center)

        Text(station.subtitle)
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Text("Last updated \(station.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }

      if !station.orderedSongs.isEmpty {
        HStack(spacing: 16) {
          Button {
            playback.playQueue(station.orderedSongs, from: .radio)
          } label: {
            HStack {
              Image(systemName: "play.fill")
              Text("Play")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(themeManager.accentColor)
            .clipShape(Capsule())
          }

          Button {
            playback.shuffleMode = .on
            playback.playQueue(station.orderedSongs.shuffled(), from: .radio)
          } label: {
            HStack {
              Image(systemName: "shuffle")
              Text("Shuffle")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(themeManager.cardBackgroundColor)
            .clipShape(Capsule())
            .overlay(
              Capsule()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
          }
        }
      }
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }

  private var platformListStyle: some ListStyle {
    #if os(iOS)
      .insetGrouped
    #else
      .inset
    #endif
  }

  private func saveAsPlaylist() {
    playlistManager.createPlaylist(
      name: station.name + " (Radio)",
      description: "Saved from your personal radio station on \(Date().formatted(date: .numeric, time: .omitted))",
      songs: station.orderedSongs
    )
  }
}

struct RadioArtworkCollage: View {
  let artworkPaths: [String]
  let colors: [Color]
  let size: CGFloat

  var body: some View {
    let half = size / 2
    ZStack {
      LinearGradient(
        colors: colors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      LazyVGrid(
        columns: [
          GridItem(.fixed(half), spacing: 0),
          GridItem(.fixed(half), spacing: 0),
        ],
        spacing: 0
      ) {
        ForEach(0..<4, id: \.self) { idx in
          let path = idx < artworkPaths.count ? artworkPaths[idx] : nil
          AlbumArtworkView(
            artworkPath: path,
            size: half,
            cornerRadius: 0
          )
          .frame(width: half, height: half)
        }
      }
    }
    .frame(width: size, height: size)
  }
}

#Preview {
  NavigationStack {
    PlaylistView(playlist: Playlist(name: "My Playlist"))
  }
}
