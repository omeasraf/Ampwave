//
//  SongEditSheet.swift
//  Ampwave
//
//  Sheet for editing song metadata.
//

import SwiftData
internal import SwiftUI

struct SongEditSheet: View {
  let song: LibrarySong
  @Binding var isPresented: Bool

  @State private var title: String
  @State private var artist: String
  @State private var album: String
  @State private var year: String
  @State private var genre: String
  @State private var trackNumber: String

  private var library: SongLibrary { SongLibrary.shared }

  init(song: LibrarySong, isPresented: Binding<Bool>) {
    self.song = song
    self._isPresented = isPresented
    _title = State(initialValue: song.title)
    _artist = State(initialValue: song.artist)
    _album = State(initialValue: song.album ?? "")
    _year = State(initialValue: song.year.map(String.init) ?? "")
    _genre = State(initialValue: song.genre ?? "")
    _trackNumber = State(initialValue: song.trackNumber.map(String.init) ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Basic Info") {
          TextField("Title", text: $title)
          TextField("Artist", text: $artist)
          TextField("Album", text: $album)
        }

        Section("Details") {
          TextField("Genre", text: $genre)
          TextField("Year", text: $year)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
          TextField("Track Number", text: $trackNumber)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
        }
      }
      .navigationTitle("Edit Song")
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
              saveSongMetadata()
              isPresented = false
            }
            .disabled(title.isEmpty || artist.isEmpty)
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
              saveSongMetadata()
              isPresented = false
            }
            .disabled(title.isEmpty || artist.isEmpty)
          }
        }
      #endif
    }
  }

  private func saveSongMetadata() {
    song.title = title
    song.artist = artist
    song.album = album.isEmpty ? nil : album
    song.genre = genre.isEmpty ? nil : genre

    if let yearInt = Int(year), yearInt > 0 {
      song.year = yearInt
    }

    if let trackInt = Int(trackNumber), trackInt > 0 {
      song.trackNumber = trackInt
    }

    // Persist changes
    if let modelContext = library.modelContext {
      do {
        try modelContext.save()
      } catch {}
    }
  }
}
