//
//  CreatePlaylistSheet.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/10/26.
//

import PhotosUI
internal import SwiftUI

struct CreatePlaylistSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""

  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
  @State private var artworkData: Data?
  @State private var artworkPath: String?
  @State private var artworkImage: Image?
  @State private var artworkType: PlaylistArtworkType = .grid

  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Playlist Name", text: $name)
          TextField("Description (Optional)", text: $description)
        }

        Section {
          Picker("Artwork Style", selection: $artworkType) {
            Label("Grid (2x2)", systemImage: "square.grid.2x2").tag(
              PlaylistArtworkType.grid
            )
            Label("First Song", systemImage: "square").tag(
              PlaylistArtworkType.single
            )
            Label("Custom", systemImage: "photo").tag(
              PlaylistArtworkType.custom
            )
          }
          .pickerStyle(.menu)

          if artworkType == .custom {
            artworkSelectionSection
          }

          Text(
            "Additional customization options will be available in a future update."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } header: {
          Text("Artwork")
        }
      }
      .navigationTitle("New Playlist")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: selectedPhotoItem) { _, newItem in
        Task {
          if let data = try? await newItem?.loadTransferable(type: Data.self) {
            #if os(iOS)
              if let uiImage = UIImage(data: data) {
                artworkData = data
                artworkImage = Image(uiImage: uiImage)
                artworkType = .custom
              }
            #else
              if let nsImage = NSImage(data: data) {
                artworkData = data
                artworkImage = Image(nsImage: nsImage)
                artworkType = .custom
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
                  artworkType = .custom
                }
              #else
                if let nsImage = NSImage(data: data) {
                  artworkData = data
                  artworkImage = Image(nsImage: nsImage)
                  artworkType = .custom
                }
              #endif
            }
          }
        case .failure:
          break
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            Task {
              var finalArtworkPath: String? = nil
              if artworkType == .custom, let data = artworkData {
                finalArtworkPath = await library.cacheArtwork(data)
              }

              playlistManager.createPlaylist(
                name: name,
                description: description.isEmpty ? nil : description,
                artworkType: artworkType,
                artworkPath: finalArtworkPath
              )
              dismiss()
            }
          }
          .disabled(name.isEmpty)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder
  private var artworkSelectionSection: some View {
    HStack(spacing: 15) {
      if let image = artworkImage {
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 80, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else if artworkType == .custom, let path = artworkPath,
        let url = PathManager.resolve(path)
      {
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
          if artworkPath != nil || artworkImage != nil || artworkData != nil {
            Button(role: .destructive) {
              artworkImage = nil
              artworkData = nil
              artworkPath = nil
              artworkType = .grid
            } label: {
              Label(
                "Reset",
                systemImage: "arrow.counterclockwise"
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
}
