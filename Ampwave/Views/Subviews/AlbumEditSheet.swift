//
//  AlbumEditSheet.swift
//  Ampwave
//
//  Sheet for editing album metadata.
//

import SwiftData
internal import SwiftUI

struct AlbumEditSheet: View {
  let album: Album
  @Binding var isPresented: Bool

  @State private var name: String
  @State private var artist: String
  @State private var year: String
  @State private var genre: String

  private var library: SongLibrary { SongLibrary.shared }

  init(album: Album, isPresented: Binding<Bool>) {
    self.album = album
    self._isPresented = isPresented
    _name = State(initialValue: album.name)
    _artist = State(initialValue: album.artist ?? "")
    _year = State(initialValue: album.year.map(String.init) ?? "")
    _genre = State(initialValue: album.genre?.joined(separator: ", ") ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Album Info") {
          TextField("Album Name", text: $name)
          TextField("Artist", text: $artist)
        }

        Section("Details") {
          TextField("Year", text: $year)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
          TextField("Genre", text: $genre)
        }

        Section("Songs") {
          Text("\(album.songCount) song\(album.songCount != 1 ? "s" : "")")
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Edit Album")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
              isPresented = false
            }
          }

          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
              saveAlbumMetadata()
              isPresented = false
            }
            .disabled(name.isEmpty)
          }
        }
      #else
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              isPresented = false
            }
          }

          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              saveAlbumMetadata()
              isPresented = false
            }
            .disabled(name.isEmpty)
          }
        }
      #endif
    }
  }

  private func saveAlbumMetadata() {
    album.name = name
    album.artist = artist.isEmpty ? nil : artist

    if let yearInt = Int(year), yearInt > 0 {
      album.year = yearInt
    }

    if !genre.isEmpty {
      album.genre = genre.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    } else {
      album.genre = nil
    }

    // Persist changes
    if let modelContext = library.modelContext {
      do {
        try modelContext.save()
      } catch {}
    }
  }
}
