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

  private var library: SongLibrary { SongLibrary.shared }

  init(album: Album, isPresented: Binding<Bool>) {
    self.album = album
    self._isPresented = isPresented
    _name = State(initialValue: album.name)
    _artist = State(initialValue: album.artist ?? "")
    _year = State(initialValue: album.year.map(String.init) ?? "")
    _genre = State(initialValue: album.genre?.joined(separator: ", ") ?? "")
    _artworkPath = State(initialValue: album.artworkPath)
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
                }

                Spacer()

                if artworkPath != nil || artworkImage != nil {
                  Button(role: .destructive) {
                    artworkImage = nil
                    artworkData = nil
                    artworkPath = nil
                  } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                      .font(.caption)
                  }
                  .buttonStyle(.bordered)
                }
              }
            }
          }
          .padding(.vertical, 5)
        }

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
      .onChange(of: selectedPhotoItem) { _, newItem in
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
      }
    } else if artworkPath == nil {
      album.artworkPath = nil
    }

    // Persist changes
    if let modelContext = library.modelContext {
      do {
        try modelContext.save()
      } catch {}
    }
  }
}
