//
//  PlaylistView.swift
//  Ampwave
//
//  Playlist detail view with cover, title, description, and editable track list.
//

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
                            playback.playPlaylist(playlist, startingAt: playlist.songs.firstIndex(where: { $0.id == song.id }) ?? 0)
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
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Edit Details", systemImage: "pencil")
                    }
                    
                    Button {
                        showingAddSongsSheet = true
                    } label: {
                        Label("Add Songs", systemImage: "plus")
                    }
                    
                    Button {
                        isEditing.toggle()
                    } label: {
                        Label(isEditing ? "Done" : "Edit Order", systemImage: isEditing ? "checkmark" : "arrow.up.arrow.down")
                    }
                    
                    Divider()
                    
                    Button {
                        playlistManager.togglePin(playlist)
                    } label: {
                        Label(playlist.isPinned ? "Unpin" : "Pin", systemImage: playlist.isPinned ? "pin.slash" : "pin")
                    }
                    
                    if playlist.playlistType == .custom || playlist.playlistType == .smart {
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
                artworkPath: playlist.artworkPath,
                size: 200,
                icon: playlist.icon
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
                    Text("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
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
                        let randomStartIndex = Int.random(in: 0..<playlist.songs.count)
                        playback.playPlaylist(playlist, startingAt: randomStartIndex)
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

// MARK: - Edit Playlist Sheet

struct EditPlaylistSheet: View {
    let playlist: Playlist
    
    @State private var name: String
    @State private var description: String
    @Environment(\.dismiss) private var dismiss
    
    private var playlistManager: PlaylistManager { PlaylistManager.shared }
    
    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _description = State(initialValue: playlist.playlistDescription ?? "")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section {
                    Button {
                        // Change cover image
                    } label: {
                        Label("Change Cover", systemImage: "photo")
                    }
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        playlistManager.updatePlaylist(
                            playlist,
                            name: name,
                            description: description.isEmpty ? nil : description
                        )
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Add Songs to Playlist Sheet

struct AddSongsToPlaylistSheet: View {
    let playlist: Playlist
    
    @State private var searchText = ""
    @State private var selectedSongs = Set<UUID>()
    @Environment(\.dismiss) private var dismiss
    
    private var library: SongLibrary { SongLibrary.shared }
    private var playlistManager: PlaylistManager { PlaylistManager.shared }
    
    var filteredSongs: [LibrarySong] {
        let existingIds = Set(playlist.songs.map { $0.id })
        let availableSongs = library.songs.filter { !existingIds.contains($0.id) }
        
        if searchText.isEmpty {
            return availableSongs
        }
        
        return availableSongs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if filteredSongs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Songs Available",
                            systemImage: "music.note",
                            description: Text("All songs are already in this playlist")
                        )
                    }
                } else {
                    Section {
                        ForEach(filteredSongs) { song in
                            HStack {
                                SongRow(song: song, isCurrent: false)
                                
                                Spacer()
                                
                                if selectedSongs.contains(song.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.pink)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedSongs.contains(song.id) {
                                    selectedSongs.remove(song.id)
                                } else {
                                    selectedSongs.insert(song.id)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search songs")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedSongs.count))") {
                        let songsToAdd = library.songs.filter { selectedSongs.contains($0.id) }
                        playlistManager.addSongs(songsToAdd, to: playlist)
                        dismiss()
                    }
                    .disabled(selectedSongs.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistView(playlist: Playlist(name: "My Playlist"))
    }
}
