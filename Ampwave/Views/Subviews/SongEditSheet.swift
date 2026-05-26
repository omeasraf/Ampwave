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
  @Environment(ThemeManager.self) private var themeManager

  @State private var title: String
  @State private var artist: String
  @State private var album: String
  @State private var year: String
  @State private var genre: String
  @State private var trackNumber: String
  @State private var lyrics: String
  @State private var rating: Int
  @State private var isLoadingLyrics: Bool = false

  // Artwork
  @State private var artworkImage: Image?
  @State private var artworkData: Data?
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
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

                    if let embedded = song.embeddedArtworkPath,
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
          Text("Fetches title, artist, album, and year from MusicBrainz.")
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
        .listRowBackground(themeManager.cardBackgroundColor)
      }
      .background(themeManager.backgroundColor)
      .scrollContentBackground(.hidden)
      .tint(themeManager.accentColor)
      .navigationTitle("Edit Song")
      .sheet(isPresented: $isShowingArtworkSelection) {
        ArtworkSelectionSheet(title: title, artist: artist, isPresented: $isShowingArtworkSelection)
        { url in
          Task {
            if let data = await MetadataService.shared.performRequest(url: url) {
              #if os(iOS)
                if let uiImage = UIImage(data: data) {
                  await MainActor.run {
                    artworkData = data
                    artworkImage = Image(uiImage: uiImage)
                    isRemoteArtwork = true
                    artworkPath = nil  // Clear current path since we have new data
                  }
                }
              #else
                if let nsImage = NSImage(data: data) {
                  await MainActor.run {
                    artworkData = data
                    artworkImage = Image(nsImage: nsImage)
                    isRemoteArtwork = true
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

  private var artworkSourceLabel: String {
    switch artworkSource {
    case .embedded: return "Embedded Artwork"
    case .online: return "MusicBrainz Artwork"
    case .user: return "User Selected Artwork"
    }
  }

  private func markFieldAsEdited(_ field: String) {
    if !song.userEditedFields.contains(field) {
      song.userEditedFields.append(field)
    }
  }

  private func fetchOnlineMetadata() {
    isFetchingMetadata = true
    Task {
      if let metadata = await MetadataService.shared.fetchMetadata(for: song) {
        await MainActor.run {
          // Apply changes only if not edited by user
          if !song.userEditedFields.contains("title"), let newTitle = metadata.title {
            title = newTitle
          }
          if !song.userEditedFields.contains("artist"), let newArtist = metadata.artist {
            artist = newArtist
          }
          if !song.userEditedFields.contains("album"), let newAlbum = metadata.album {
            album = newAlbum
          }
          if !song.userEditedFields.contains("year"), let newYear = metadata.year {
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
        song.artworkSource = .user

        // Update album artwork if primary
        if let album = song.albumReference,
          album.artworkPath == nil || album.songs.first?.id == song.id
        {
          album.artworkPath = newPath
          album.artworkSource = .user
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
    LyricsService.shared.saveLyrics(for: song, content: lyrics)
    historyTracker.setRating(rating == 0 ? nil : rating, for: song)

    // Persist changes using library service to update search index version
    library.saveContext()
  }
}
