//
//  SongEditSheet.swift
//  Ampwave
//
//  Sheet for editing song metadata.
//

import PhotosUI
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

  // Artwork
  @State private var artworkImage: Image?
  @State private var artworkData: Data?
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
  @State private var isRemoteArtwork: Bool
  @State private var artworkPath: String?

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
    _trackNumber = State(
      initialValue: song.trackNumber.map(String.init) ?? ""
    )
    _lyrics = State(initialValue: song.lyrics ?? "")

    _isRemoteArtwork = State(initialValue: song.isRemoteArtwork)
    _artworkPath = State(initialValue: song.artworkPath)

    _sampleRate = State(
      initialValue: song.sampleRate.map { String(format: "%.0f", $0) }
        ?? ""
    )
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
        Section("Artwork") {
          HStack(spacing: 15) {
            if let image = artworkImage {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let path = artworkPath,
              let url = PathManager.resolve(path)
            {
              #if os(iOS)
                if let uiImage = UIImage(
                  contentsOfFile: url.path
                ) {
                  Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(
                      RoundedRectangle(cornerRadius: 8)
                    )
                } else {
                  placeholderView
                }
              #else
                if let nsImage = NSImage(
                  contentsOfFile: url.path
                ) {
                  Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(
                      RoundedRectangle(cornerRadius: 8)
                    )
                } else {
                  placeholderView
                }
              #endif
            } else {
              placeholderView
            }

            VStack(alignment: .leading, spacing: 5) {
              Text(
                isRemoteArtwork
                  ? "Remote Artwork" : "Local Artwork"
              )
              .font(.subheadline)
              .foregroundStyle(.secondary)

              HStack {
                VStack(alignment: .leading, spacing: 5) {
                  PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images
                  ) {
                    Label("Photos", systemImage: "photo")
                      .font(.caption)
                  }
                  .buttonStyle(.bordered)

                  Button {
                    isShowingFilePicker = true
                  } label: {
                    Label("Files", systemImage: "folder")
                      .font(.caption)
                  }
                  .buttonStyle(.bordered)
                }

                Spacer()

                if artworkPath != nil || artworkImage != nil {
                  Button(role: .destructive) {
                    artworkImage = nil
                    artworkData = nil
                    artworkPath = nil
                    isRemoteArtwork = false
                  } label: {
                    Label(
                      "Reset",
                      systemImage:
                        "arrow.counterclockwise"
                    )
                    .font(.caption)
                  }
                  .buttonStyle(.bordered)
                }
              }
            }
          }
          .padding(.vertical, 5)
        }

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
                  if await LyricsService.shared
                    .fetchOnlineLyrics(for: song) != nil
                  {
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
      .onChange(of: selectedPhotoItem) { _, newItem in
        Task {
          if let data = try? await newItem?.loadTransferable(
            type: Data.self
          ) {
            #if os(iOS)
              if let uiImage = UIImage(data: data) {
                artworkData = data
                artworkImage = Image(uiImage: uiImage)
                isRemoteArtwork = false
              }
            #else
              if let nsImage = NSImage(data: data) {
                artworkData = data
                artworkImage = Image(nsImage: nsImage)
                isRemoteArtwork = false
              }
            #endif
          }
        }
      }
      .fileImporter(
        isPresented: $isShowingFilePicker,
        allowedContentTypes: [.image],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let url = urls.first else { return }
          if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
              #if os(iOS)
                if let uiImage = UIImage(data: data) {
                  artworkData = data
                  artworkImage = Image(uiImage: uiImage)
                  isRemoteArtwork = false
                }
              #else
                if let nsImage = NSImage(data: data) {
                  artworkData = data
                  artworkImage = Image(nsImage: nsImage)
                  isRemoteArtwork = false
                }
              #endif
            }
          }
        case .failure:
          break
        }
      }
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
              Task {
                await saveSongMetadata()
                isPresented = false
              }
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
              Task {
                await saveSongMetadata()
                isPresented = false
              }
            }
            .disabled(title.isEmpty || artist.isEmpty)
          }
        }
      #endif
    }
  }

  @ViewBuilder
  private var placeholderView: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(Color.secondary.opacity(0.2))
      .frame(width: 80, height: 80)
      .overlay {
        Image(systemName: "music.note")
          .foregroundStyle(.secondary)
      }
  }

  private func saveSongMetadata() async {
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

    // Save artwork if changed
    if let data = artworkData {
      if let newPath = await library.cacheArtwork(data) {
        song.artworkPath = newPath

        // Update album artwork if primary
        if let album = song.albumReference,
          album.artworkPath == nil || album.songs.first?.id == song.id
        {
          album.artworkPath = newPath
        }
      }
    }

    song.isRemoteArtwork = isRemoteArtwork

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
