//
//  PlaylistsListView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/11/26.
//

import SwiftData
internal import SwiftUI

struct PlaylistsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var showingCreateSheet = false
    @State private var showUnpinAlert = false
    @State private var searchText = ""

    private var playlistManager: PlaylistManager { PlaylistManager.shared }

    private var appSettings: AppSettings {
        settings.first ?? AppSettings.getOrCreate(in: modelContext)
    }

    var filteredPlaylists: [Playlist] {
        let playlists: [Playlist]
        if searchText.isEmpty {
            playlists = playlistManager.playlists
        } else {
            playlists = playlistManager.playlists.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        return sortPlaylists(playlists)
    }

    private func sortPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        // We want to keep Liked Songs and Pinned playlists at top, then apply sort
        var sorted = playlists

        sorted.sort { p1, p2 in
            // 1. Liked Songs always at the top
            if p1.playlistType == .likedSongs && p2.playlistType != .likedSongs
            {
                return true
            }
            if p2.playlistType == .likedSongs && p1.playlistType != .likedSongs
            {
                return false
            }

            // 2. Pinned playlists next
            if p1.isPinned != p2.isPinned {
                return p1.isPinned && !p2.isPinned
            }

            // 3. Apply user's selected sort order for the rest
            switch appSettings.playlistSortOrder {
            case .titleAscending:
                return p1.name.localizedCaseInsensitiveCompare(p2.name)
                    == .orderedAscending
            case .titleDescending:
                return p1.name.localizedCaseInsensitiveCompare(p2.name)
                    == .orderedDescending
            case .dateAddedDescending:
                return p1.createdDate > p2.createdDate
            case .dateAddedAscending:
                return p1.createdDate < p2.createdDate
            case .random:
                return p1.id.uuidString < p2.id.uuidString
            default:
                return p1.name.localizedCaseInsensitiveCompare(p2.name)
                    == .orderedAscending
            }
        }

        return sorted
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("New Playlist", systemImage: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .listRowBackground(Color.clear)
                .sheet(isPresented: $showingCreateSheet) {
                    CreatePlaylistSheet()
                }

                ForEach(filteredPlaylists) { playlist in
                    NavigationLink(
                        destination: PlaylistView(playlist: playlist)
                    ) {
                        HStack(spacing: 12) {
                            PlaylistArtworkView(
                                playlist: playlist,
                                size: 60
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.system(size: 16, weight: .medium))

                                Text(
                                    "\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")"
                                )
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if playlist.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if playlist.playlistType != .likedSongs {
                            if playlist.playlistType == .custom
                                || playlist.playlistType == .smart
                            {
                                Button(role: .destructive) {
                                    if playlist.isPinned {
                                        showUnpinAlert = true
                                    } else {
                                        playlistManager.deletePlaylist(playlist)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .opacity(playlist.isPinned ? 0.5 : 1.0)  // Visual disable cue
                            }

                            Button {
                                playlistManager.togglePin(playlist)
                            } label: {
                                Image(
                                    systemName: playlist.isPinned
                                        ? "pin.slash" : "pin"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                    .alert("Cannot Delete", isPresented: $showUnpinAlert) {
                        Button("OK") {}
                    } message: {
                        Text("Unpin the playlist first.")
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if playlistManager.playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "list.bullet",
                        description: Text("Create your first playlist")
                    )
                } else if filteredPlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No playlists match your search")
                    )
                }
            }.listStyle(.plain)
                .navigationTitle("Playlists")
                .searchable(text: $searchText, prompt: "Search in Playlists")
        }.onAppear {
            playlistManager.setModelContext(modelContext)
        }
    }
}
