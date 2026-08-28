//
//  LibraryCleanupView.swift
//  Ampwave
//
//  Tracks whose audio file has gone missing. Complements Review Missing
//  Metadata (incomplete tags on tracks that still play) and Manage Duplicates.
//

import SwiftData
internal import SwiftUI

struct MissingFilesView: View {
  @Environment(ThemeManager.self) private var themeManager

  @State private var missing: [LibrarySong] = []
  @State private var isScanning = true

  private var library: SongLibrary { SongLibrary.shared }

  var body: some View {
    Group {
      if isScanning {
        ProgressView("Checking files…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if missing.isEmpty {
        VStack(spacing: 20) {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 60))
            .foregroundStyle(themeManager.accentColor)
          Text("Nothing is missing")
            .font(.headline)
          Text("Every track in your library still has its audio file.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          Section {
            Text(
              "\(missing.count) track\(missing.count == 1 ? "" : "s") can't be played — the audio file is gone. Removing only deletes the library entry."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
          .listRowBackground(Color.clear)

          ForEach(missing) { song in
            VStack(alignment: .leading, spacing: 2) {
              Text(song.title).font(.subheadline.weight(.medium))
              Text(song.artist).font(.caption).foregroundStyle(.secondary)
            }
            .listRowBackground(themeManager.cardBackgroundColor)
          }
          .onDelete { offsets in
            for index in offsets { library.deleteSong(missing[index]) }
            missing.remove(atOffsets: offsets)
          }

          Section {
            Button(role: .destructive) {
              for song in missing { library.deleteSong(song) }
              missing.removeAll()
            } label: {
              Label("Remove All Missing Tracks", systemImage: "trash")
            }
          }
          .listRowBackground(themeManager.cardBackgroundColor)
        }
        #if os(iOS)
          .listStyle(.insetGrouped)
        #endif
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle("Missing Files")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .task(id: library.libraryVersion) { scan() }
  }

  private func scan() {
    missing = LibraryMaintenanceService.findMissingFiles(in: library.songs, library: library)
    isScanning = false
  }
}

// MARK: - Bulk tag editor

/// Multi-select tag editing. Review Missing Metadata fixes one song at a time;
/// this is for the "this whole folder has the wrong artist" case.
struct BulkTagEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var searchText = ""
  @State private var selection = Set<UUID>()
  @State private var artist = ""
  @State private var albumArtist = ""
  @State private var album = ""
  @State private var genre = ""
  @State private var year = ""

  private var library: SongLibrary { SongLibrary.shared }

  private var filteredSongs: [LibrarySong] {
    guard !searchText.isEmpty else { return library.songs }
    return library.songs.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.artist.localizedCaseInsensitiveContains(searchText)
        || ($0.album ?? "").localizedCaseInsensitiveContains(searchText)
    }
  }

  private var edit: LibraryMaintenanceService.TagEdit {
    LibraryMaintenanceService.TagEdit(
      artist: artist.isEmpty ? nil : artist,
      albumArtist: albumArtist.isEmpty ? nil : albumArtist,
      album: album.isEmpty ? nil : album,
      genre: genre.isEmpty ? nil : genre,
      year: year.isEmpty ? nil : Int(year)
    )
  }

  private var allFilteredSelected: Bool {
    !filteredSongs.isEmpty && filteredSongs.allSatisfy { selection.contains($0.id) }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Artist", text: $artist).textInputAutocapitalization(.words)
          TextField("Album Artist", text: $albumArtist).textInputAutocapitalization(.words)
          TextField("Album", text: $album).textInputAutocapitalization(.words)
          TextField("Genre", text: $genre).textInputAutocapitalization(.words)
          #if os(iOS)
            TextField("Year", text: $year).keyboardType(.numberPad)
          #else
            TextField("Year", text: $year)
          #endif
        } header: {
          Text("Set fields")
        } footer: {
          Text(
            "Blank fields are left untouched. Edits are marked so metadata fetches won't overwrite them."
          )
        }

        Section("Apply to \(selection.count) song\(selection.count == 1 ? "" : "s")") {
          ForEach(filteredSongs, id: \.id) { song in
            Button {
              if selection.contains(song.id) {
                selection.remove(song.id)
              } else {
                selection.insert(song.id)
              }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(song.title).foregroundStyle(.primary)
                  Text("\(song.artist) — \(song.album ?? "No album")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(selection.contains(song.id) ? Color.accentColor : .secondary)
              }
            }
          }
        }
      }
      .searchable(text: $searchText, prompt: "Filter songs")
      .navigationTitle("Bulk Tag Editor")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          // Filter to an album, then take the whole thing in one tap — the
          // common case when a folder imported with the wrong artist.
          Button(allFilteredSelected ? "Deselect All" : "Select All") {
            if allFilteredSelected {
              filteredSongs.forEach { selection.remove($0.id) }
            } else {
              filteredSongs.forEach { selection.insert($0.id) }
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") { apply() }
            .disabled(selection.isEmpty || edit.isEmpty)
        }
      }
    }
  }

  private func apply() {
    let songs = library.songs.filter { selection.contains($0.id) }
    LibraryMaintenanceService.applyTags(edit, to: songs, modelContext: modelContext)
    PlaylistManager.shared.refreshAllSmartPlaylists()
    dismiss()
  }
}
