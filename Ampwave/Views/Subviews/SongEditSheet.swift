//
//  SongEditSheet.swift
//  Ampwave
//
//  Sheet for editing song metadata.
//

import PhotosUI
import SwiftData
internal import SwiftUI
import UniformTypeIdentifiers

struct SongEditSheet: View {
  private enum FileImportMode {
    case artwork
    case lyrics
  }

  private static let lrcContentType = UTType(filenameExtension: "lrc") ?? .plainText

  let songID: UUID
  let embeddedArtworkPath: String?
  @Binding var isPresented: Bool
  @Environment(ThemeManager.self) private var themeManager

  @State private var title: String
  @State private var artist: String
  @State private var album: String
  @State private var year: String
  @State private var genre: String
  @State private var trackNumber: String
  @State private var discNumber: String
  @State private var isExplicit: Bool
  @State private var lyrics: String
  @State private var rating: Int
  @State private var isLoadingLyrics: Bool = false

  // Artwork
  @State private var artworkImage: Image?
  @State private var artworkData: Data?
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
  @State private var fileImportMode: FileImportMode = .artwork
  @State private var lyricImportError: String?
  @State private var isRemoteArtwork: Bool
  @State private var artworkPath: String?
  @State private var artworkSource: LibrarySong.ArtworkSource
  @State private var isShowingArtworkSelection = false
  @State private var isFetchingMetadata = false

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
  private var historyTracker: ListeningHistoryTracker { ListeningHistoryTracker.shared }

  init(song: LibrarySong, isPresented: Binding<Bool>) {
    self.songID = song.id
    self.embeddedArtworkPath = song.embeddedArtworkPath
    self._isPresented = isPresented
    _title = State(initialValue: song.title)
    _artist = State(initialValue: song.artist)
    _album = State(initialValue: song.album ?? "")
    _year = State(initialValue: song.year.map(String.init) ?? "")
    _genre = State(initialValue: song.genre ?? "")
    _trackNumber = State(
      initialValue: song.trackNumber.map(String.init) ?? ""
    )
    _discNumber = State(
      initialValue: song.discNumber.map(String.init) ?? ""
    )
    _isExplicit = State(initialValue: song.isExplicit)
    _lyrics = State(initialValue: song.lyrics ?? "")
    _rating = State(initialValue: ListeningHistoryTracker.shared.rating(for: song) ?? 0)

    _isRemoteArtwork = State(initialValue: song.isRemoteArtwork)
    _artworkPath = State(initialValue: song.artworkPath)
    _artworkSource = State(initialValue: song.artworkSource)

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
              HStack {
                Text(artworkSourceLabel)
                  .font(.caption)
                  .fontWeight(.medium)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 2)
                  .background(themeManager.accentColor.opacity(0.1))
                  .foregroundStyle(themeManager.accentColor)
                  .clipShape(Capsule())

                Spacer()
              }

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
                    fileImportMode = .artwork
                    isShowingFilePicker = true
                  } label: {
                    Label("Files", systemImage: "folder")
                      .font(.caption)
                  }
                  .buttonStyle(.bordered)

                  Button {
                    isShowingArtworkSelection = true
                  } label: {
                    Label("Search Online", systemImage: "globe")
                      .font(.caption)
                  }
                  .buttonStyle(.bordered)
                }

                Spacer()

                if artworkPath != nil || artworkImage != nil {
                  VStack(alignment: .trailing, spacing: 5) {
                    Button(role: .destructive) {
                      artworkImage = nil
                      artworkData = nil
                      artworkPath = nil
                      artworkSource = .embedded
                      isRemoteArtwork = false
                    } label: {
                      Label(
                        "Remove",
                        systemImage: "trash"
                      )
                      .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    if let embedded = embeddedArtworkPath,
                      embedded != artworkPath || artworkImage != nil
                    {
                      Button {
                        artworkImage = nil
                        artworkData = nil
                        artworkPath = embedded
                        artworkSource = .embedded
                        isRemoteArtwork = false
                        print("[DEBUG] SongEditSheet: Reverting to embedded artwork: \(embedded)")
                      } label: {
                        Label(
                          "Original",
                          systemImage: "arrow.revert.quarters"
                        )
                        .font(.caption)
                      }
                      .buttonStyle(.bordered)
                    }
                  }
                }
              }
            }
          }
          .padding(.vertical, 5)
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section {
          Button {
            fetchOnlineMetadata()
          } label: {
            HStack {
              if isFetchingMetadata {
                ProgressView()
                  .controlSize(.small)
                  .padding(.trailing, 5)
              }
              Label("Fetch Song Info Online", systemImage: "magnifyingglass.circle")
            }
          }
          .disabled(isFetchingMetadata)
        } header: {
          Text("Metadata Discovery")
        } footer: {
          Text("Uses Apple Music when access is available, then falls back to MusicBrainz.")
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Basic Info") {
          TextField("Title", text: $title)
            .onChange(of: title) { markFieldAsEdited("title") }
          TextField("Artist", text: $artist)
            .onChange(of: artist) { markFieldAsEdited("artist") }
          TextField("Album", text: $album)
            .onChange(of: album) { markFieldAsEdited("album") }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Details") {
          TextField("Genre", text: $genre)
            .onChange(of: genre) { markFieldAsEdited("genre") }
          TextField("Year", text: $year)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .onChange(of: year) { markFieldAsEdited("year") }
          TextField("Track Number", text: $trackNumber)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .onChange(of: trackNumber) { markFieldAsEdited("trackNumber") }
          TextField("Disc Number", text: $discNumber)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .onChange(of: discNumber) { markFieldAsEdited("discNumber") }
          Toggle("Explicit", isOn: $isExplicit)
            .onChange(of: isExplicit) { markFieldAsEdited("isExplicit") }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Preference") {
          Picker("Rating", selection: $rating) {
            Text("None").tag(0)
            ForEach(1...5, id: \.self) { value in
              Text(String(repeating: "★", count: value)).tag(value)
            }
          }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

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
        .listRowBackground(themeManager.cardBackgroundColor)

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
                  if let liveSong = library.song(id: songID),
                    await LyricsService.shared.fetchOnlineLyrics(for: liveSong) != nil,
                    let refreshedSong = library.song(id: songID)
                  {
                    lyrics = refreshedSong.lyrics ?? ""
                  }
                  isLoadingLyrics = false
                }
              }
              .font(.caption)
              .buttonStyle(.bordered)

              Button("Import File") {
                lyricImportError = nil
                fileImportMode = .lyrics
                isShowingFilePicker = true
              }
              .font(.caption)
              .buttonStyle(.bordered)
            }
          }

          if let lyricImportError {
            Text(lyricImportError)
              .font(.caption)
              .foregroundStyle(.red)
          }

          TextEditor(text: $lyrics)
            .frame(minHeight: 200)
            .font(.system(.body, design: .monospaced))
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }
      .background(themeManager.backgroundColor)
      .scrollContentBackground(.hidden)
      .tint(themeManager.accentColor)
      .navigationTitle("Edit Song")
      .sheet(isPresented: $isShowingArtworkSelection) {
        ArtworkSelectionSheet(
          title: title,
          artist: artist,
          album: album,
          isPresented: $isShowingArtworkSelection
        )
        { url in
          Task {
            if let data = await MetadataService.shared.performRequest(url: url) {
              #if os(iOS)
                if let uiImage = UIImage(data: data) {
                  await MainActor.run {
                    artworkData = data
                    artworkImage = Image(uiImage: uiImage)
                    isRemoteArtwork = true
                    artworkSource = .online
                    artworkPath = nil  // Clear current path since we have new data
                  }
                }
              #else
                if let nsImage = NSImage(data: data) {
                  await MainActor.run {
                    artworkData = data
                    artworkImage = Image(nsImage: nsImage)
                    isRemoteArtwork = true
                    artworkSource = .online
                    artworkPath = nil
                  }
                }
              #endif
            }
          }
        }
      }
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
                artworkSource = .user
              }
            #else
              if let nsImage = NSImage(data: data) {
                artworkData = data
                artworkImage = Image(nsImage: nsImage)
                isRemoteArtwork = false
                artworkSource = .user
              }
            #endif
          }
        }
      }
      .fileImporter(
        isPresented: $isShowingFilePicker,
        allowedContentTypes: fileImportMode == .artwork
          ? [.image]
          : [Self.lrcContentType, .plainText],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let url = urls.first else { return }
          let secured = url.startAccessingSecurityScopedResource()
          defer { if secured { url.stopAccessingSecurityScopedResource() } }

          if fileImportMode == .lyrics {
            do {
              let data = try Data(contentsOf: url)
              guard let imported = decodeLyrics(data), !imported.isEmpty else {
                lyricImportError = "The selected file doesn’t contain readable lyrics."
                return
              }
              lyrics = imported
              lyricImportError = nil
            } catch {
              lyricImportError = error.localizedDescription
            }
          } else if let data = try? Data(contentsOf: url) {
              #if os(iOS)
                if let uiImage = UIImage(data: data) {
                  artworkData = data
                  artworkImage = Image(uiImage: uiImage)
                  isRemoteArtwork = false
                  artworkSource = .user
                }
              #else
                if let nsImage = NSImage(data: data) {
                  artworkData = data
                  artworkImage = Image(nsImage: nsImage)
                  isRemoteArtwork = false
                  artworkSource = .user
                }
              #endif
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
        AmpwaveEqualizerMark(isAnimated: false, monochromeColor: .secondary)
          .frame(width: 34, height: 23)
      }
  }

  private var artworkSourceLabel: String {
    switch artworkSource {
    case .embedded: return "Embedded Artwork"
    case .online: return "Online Artwork"
    case .user: return "User Selected Artwork"
    }
  }

  private func markFieldAsEdited(_ field: String) {
    guard let liveSong = library.song(id: songID) else { return }
    if !liveSong.userEditedFields.contains(field) {
      liveSong.userEditedFields.append(field)
    }
  }

  private func fetchOnlineMetadata() {
    isFetchingMetadata = true
    Task {
      guard let liveSong = library.song(id: songID) else {
        isFetchingMetadata = false
        return
      }
      if let metadata = await MetadataService.shared.fetchMetadata(for: liveSong) {
        await MainActor.run {
          guard let refreshedSong = library.song(id: songID) else { return }
          // Apply changes only if not edited by user
          if !refreshedSong.userEditedFields.contains("title"), let newTitle = metadata.title {
            title = newTitle
          }
          if !refreshedSong.userEditedFields.contains("artist"), let newArtist = metadata.artist {
            artist = newArtist
          }
          if !refreshedSong.userEditedFields.contains("album"), let newAlbum = metadata.album {
            album = newAlbum
          }
          if !refreshedSong.userEditedFields.contains("year"), let newYear = metadata.year {
            year = String(newYear)
          }

          if metadata.artworkURL != nil {
            isShowingArtworkSelection = true
          }
        }
      }
      isFetchingMetadata = false
    }
  }

  private func saveSongMetadata() async {
    // Artwork caching suspends. Resolve the song only after that work so a
    // concurrent library refresh cannot leave the editor with a detached model.
    let cachedArtworkPath: String?
    if let artworkData {
      cachedArtworkPath = await library.cacheArtwork(artworkData)
    } else {
      cachedArtworkPath = nil
    }

    guard let song = library.song(id: songID) else { return }
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

    if let discInt = Int(discNumber), discInt > 0 {
      song.discNumber = discInt
    }

    song.isExplicit = isExplicit

    // Save artwork if changed
    if artworkData != nil {
      if let newPath = cachedArtworkPath {
        song.artworkPath = newPath
        song.artworkSource = artworkSource

        // Update album artwork if primary
        if let album = song.albumReference,
          album.artworkPath == nil || album.songs.first?.id == song.id
        {
          album.artworkPath = newPath
          album.artworkSource = Album.ArtworkSource(rawValue: artworkSource.rawValue) ?? .user
        }
      }
    } else {
      song.artworkPath = artworkPath
      song.artworkSource = artworkSource
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
    if !song.userEditedFields.contains("lyrics") { song.userEditedFields.append("lyrics") }
    LyricsService.shared.saveLyrics(for: song, content: lyrics)
    historyTracker.setRating(rating == 0 ? nil : rating, for: song)

    // Persist changes using library service to update search index version
    library.saveContext()
  }

  private func decodeLyrics(_ data: Data) -> String? {
    let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
    for encoding in encodings {
      if let decoded = String(data: data, encoding: encoding) {
        return decoded
          .replacingOccurrences(of: "\u{feff}", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return nil
  }
}
