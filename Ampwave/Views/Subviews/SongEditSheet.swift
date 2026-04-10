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
  @State private var lyrics: String
  @State private var isLoadingLyrics: Bool = false

  // Technical Metadata
  @State private var sampleRate: String
  @State private var bitDepth: String
  @State private var bitRate: String
  @State private var format: String
  @State private var source: String
  @State private var output: String
  @State private var mode: String
  @State private var processingChain: String

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
    _lyrics = State(initialValue: song.lyrics ?? "")

    _sampleRate = State(initialValue: song.sampleRate.map { String(format: "%.0f", $0) } ?? "")
    _bitDepth = State(initialValue: song.bitDepth.map(String.init) ?? "")
    _bitRate = State(initialValue: song.bitRate.map(String.init) ?? "")
    _format = State(initialValue: song.format ?? "")
    _source = State(initialValue: song.source ?? "")
    _output = State(initialValue: song.output ?? "")
    _mode = State(initialValue: song.mode ?? "")
    _processingChain = State(initialValue: song.processingChain ?? "")
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

        Section("Technical Metadata") {
          TextField("Format", text: $format)
          TextField("Sample Rate (Hz)", text: $sampleRate)
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
          TextField("Bit Depth", text: $bitDepth)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
          TextField("Bit Rate (kbps)", text: $bitRate)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
          TextField("Source", text: $source)
          TextField("Output", text: $output)
          TextField("Mode", text: $mode)
          TextField("Processing Chain", text: $processingChain)
        }

        Section("Lyrics") {
          HStack {
            Text("Content")
            Spacer()
            if isLoadingLyrics {
              ProgressView()
                .controlSize(.small)
            } else {
              Button("Fetch Online") {
                Task {
                  isLoadingLyrics = true
                  if await LyricsService.shared.fetchOnlineLyrics(for: song) != nil {
                    lyrics = song.lyrics ?? ""
                  }
                  isLoadingLyrics = false
                }
              }
              .font(.caption)
              .buttonStyle(.bordered)
            }
          }

          TextEditor(text: $lyrics)
            .frame(minHeight: 200)
            .font(.system(.body, design: .monospaced))
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

    // Save technical metadata
    song.sampleRate = Double(sampleRate)
    song.bitDepth = Int(bitDepth)
    song.bitRate = Int(bitRate)
    song.format = format.isEmpty ? nil : format
    song.source = source.isEmpty ? nil : source
    song.output = output.isEmpty ? nil : output
    song.mode = mode.isEmpty ? nil : mode
    song.processingChain = processingChain.isEmpty ? nil : processingChain

    // Save lyrics
    LyricsService.shared.saveLyrics(for: song, content: lyrics)

    // Persist changes
    if let modelContext = library.modelContext {
      do {
        try modelContext.save()
      } catch {}
    }
  }
}
