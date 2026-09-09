//
//  WatchSyncSettingsView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct WatchSyncSettingsView: View {
  @Environment(\.modelContext) private var modelContext

  @State private var snapshot: WatchSyncSettingsSnapshot?
  @State private var refreshID = 0
  @State private var loadError: String?
  @State private var removalError: String?

  var body: some View {
    List {
      if let snapshot {
        Section(header: Text("Synced Playlists")) {
          if snapshot.playlists.isEmpty {
            Text("No playlists synced")
              .foregroundColor(.secondary)
          } else {
            ForEach(snapshot.playlists) { playlist in
              HStack {
                VStack(alignment: .leading) {
                  Text(playlist.name)
                    .font(.headline)
                  Text("\(playlist.songCount) songs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                  removePlaylist(id: playlist.id)
                } label: {
                  Image(systemName: "applewatch.slash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop syncing \(playlist.name)")
              }
            }
          }
        }

        Section(header: Text("Synced Songs")) {
          if snapshot.songs.isEmpty {
            Text("No songs synced")
              .foregroundColor(.secondary)
          } else {
            ForEach(snapshot.songs) { song in
              HStack {
                VStack(alignment: .leading) {
                  Text(song.title)
                    .font(.headline)
                  Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                  removeSong(id: song.id)
                } label: {
                  Image(systemName: "applewatch.slash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop syncing \(song.title)")
              }
            }
          }
        }
      } else if loadError == nil {
        ProgressView("Loading synced music…")
      }

      if let loadError {
        Section {
          Text(loadError)
            .foregroundStyle(.secondary)
          Button("Try Again") { refreshID &+= 1 }
        }
      }
    }
    .navigationTitle("Apple Watch Sync")
    .task(id: refreshID) {
      // Coalesce saves without doing store access in body. SwiftUI cancels
      // this load when navigating away or refreshing.
      if snapshot != nil {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      }
      await loadSnapshot()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)
    ) { _ in
      refreshID &+= 1
    }
    .alert(
      "Couldn’t Update Watch Sync",
      isPresented: Binding(
        get: { removalError != nil },
        set: { if !$0 { removalError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { removalError = nil }
    } message: {
      Text(removalError ?? "")
    }
  }

  @MainActor
  private func loadSnapshot() async {
    do {
      let result = try await WatchSyncSettingsSnapshot.load(in: modelContext.container)
      try Task.checkCancellation()
      snapshot = result
      loadError = nil
    } catch is CancellationError {
      // A cancelled navigation must not publish stale rows or an error.
    } catch {
      guard !Task.isCancelled else { return }
      loadError = "Synced music couldn’t be loaded. \(error.localizedDescription)"
    }
  }

  private func removeSong(id: UUID) {
    do {
      try WatchSyncService.shared.removeSongFromSync(id: id, in: modelContext)
      refreshID &+= 1
    } catch {
      removalError = error.localizedDescription
    }
  }

  private func removePlaylist(id: UUID) {
    do {
      try WatchSyncService.shared.removePlaylistFromSync(id: id, in: modelContext)
      refreshID &+= 1
    } catch {
      removalError = error.localizedDescription
    }
  }
}
