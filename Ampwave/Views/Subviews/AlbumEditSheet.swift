//
//  AlbumEditSheet.swift
//  Ampwave
//
//  Sheet for editing album metadata.
//

import PhotosUI
import SwiftData
internal import SwiftUI

struct AlbumEditSheet: View {
  let album: Album
  @Binding var isPresented: Bool
  @Environment(ThemeManager.self) private var themeManager

  @State private var name: String
  @State private var artist: String
  @State private var year: String
  @State private var genre: String

  // Artwork
  @State private var artworkImage: Image?
  @State private var artworkData: Data?
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
  @State private var artworkPath: String?
  @State private var artworkSource: Album.ArtworkSource
  @State private var isShowingArtworkSelection = false
  @State private var isFetchingMetadata = false

  private var library: SongLibrary { SongLibrary.shared }

  init(album: Album, isPresented: Binding<Bool>) {
    self.album = album
    self._isPresented = isPresented
    _name = State(initialValue: album.name)
    _artist = State(initialValue: album.artist ?? "")
    _year = State(initialValue: album.year.map(String.init) ?? "")
    _genre = State(initialValue: album.genre?.joined(separator: ", ") ?? "")
    _artworkPath = State(initialValue: album.artworkPath)
    _artworkSource = State(initialValue: album.artworkSource)
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
            } else if let path = artworkPath, let url = PathManager.resolve(path) {
              #if os(iOS)
                if let uiImage = UIImage(contentsOfFile: url.path) {
                  Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                  placeholderView
                }
              #else
                if let nsImage = NSImage(contentsOfFile: url.path) {
                  Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                  PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
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
                    } label: {
                      Label("Remove", systemImage: "trash")
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    if let embedded = album.embeddedArtworkPath,
                      embedded != artworkPath || artworkImage != nil
                    {
                      Button {
                        artworkImage = nil
                        artworkData = nil
                        artworkPath = embedded
                        artworkSource = .embedded
                      } label: {
                        Label("Original", systemImage: "arrow.revert.quarters")
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
              Label("Fetch Album Info Online", systemImage: "magnifyingglass.circle")
            }
          }
          .disabled(isFetchingMetadata)
        } header: {
          Text("Metadata Discovery")
        } footer: {
          Text("Fetches artist and year from MusicBrainz.")
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Album Info") {
          TextField("Album Name", text: $name)
            .onChange(of: name) { markFieldAsEdited("name") }
          TextField("Artist", text: $artist)
            .onChange(of: artist) { markFieldAsEdited("artist") }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Details") {
          TextField("Year", text: $year)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .onChange(of: year) { markFieldAsEdited("year") }
          TextField("Genre", text: $genre)
            .onChange(of: genre) { markFieldAsEdited("genre") }
        }
        .listRowBackground(themeManager.cardBackgroundColor)

        Section("Songs") {
          Text("\(album.songCount) song\(album.songCount != 1 ? "s" : "")")
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Edit Album")
      .sheet(isPresented: $isShowingArtworkSelection) {
        ArtworkSelectionSheet(title: name, artist: artist, isPresented: $isShowingArtworkSelection) { url in
          Task {
            if let data = await MetadataService.shared.performRequest(url: url) {
              #if os(iOS)
              if let uiImage = UIImage(data: data) {
                await MainActor.run {
                  artworkData = data
                  artworkImage = Image(uiImage: uiImage)
                  artworkSource = .online
                  artworkPath = nil
                }
              }
              #else
              if let nsImage = NSImage(data: data) {
                await MainActor.run {
                  artworkData = data
                  artworkImage = Image(nsImage: nsImage)
                  artworkSource = .online
                  artworkPath = nil
                }
              }
              #endif
            }
          }
        }
      }      .onChange(of: selectedPhotoItem) { _, newItem in
        Task {
          if let data = try? await newItem?.loadTransferable(type: Data.self) {
            #if os(iOS)
              if let uiImage = UIImage(data: data) {
                artworkData = data
                artworkImage = Image(uiImage: uiImage)
              }
            #else
              if let nsImage = NSImage(data: data) {
                artworkData = data
                artworkImage = Image(nsImage: nsImage)
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
                }
              #else
                if let nsImage = NSImage(data: data) {
                  artworkData = data
                  artworkImage = Image(nsImage: nsImage)
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
                await saveAlbumMetadata()
                isPresented = false
              }
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
              Task {
                await saveAlbumMetadata()
                isPresented = false
              }
            }
            .disabled(name.isEmpty)
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
    if !album.userEditedFields.contains(field) {
      album.userEditedFields.append(field)
    }
  }

  private func fetchOnlineMetadata() {
    isFetchingMetadata = true
    Task {
      if let metadata = await MetadataService.shared.fetchMetadata(for: album) {
        await MainActor.run {
          if !album.userEditedFields.contains("artist"), let newArtist = metadata.artist { artist = newArtist }
          if !album.userEditedFields.contains("year"), let newYear = metadata.year { year = String(newYear) }
          
          if metadata.artworkURL != nil {
            isShowingArtworkSelection = true
          }
        }
      }
      isFetchingMetadata = false
    }
  }

  private func saveAlbumMetadata() async {
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

    // Save artwork if changed
    if let data = artworkData {
      if let newPath = await library.cacheArtwork(data) {
        album.artworkPath = newPath
        album.artworkSource = .user
      }
    } else {
      album.artworkPath = artworkPath
      album.artworkSource = artworkSource
    }

    // Persist changes
    if let modelContext = library.modelContext {
      do {
        try modelContext.save()
      } catch {}
    }
  }
}
