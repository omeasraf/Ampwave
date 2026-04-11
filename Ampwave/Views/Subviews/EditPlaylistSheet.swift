//
//  EditPlaylistSheet.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/10/26.
//

import PhotosUI
internal import SwiftUI

struct EditPlaylistSheet: View {
  let playlist: Playlist

  @State private var name: String
  @State private var description: String
  @Environment(\.dismiss) private var dismiss

  // Artwork
  @State private var artworkImage: Image?
  @State private var artworkData: Data?
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isShowingFilePicker = false
  @State private var artworkPath: String?
  @State private var artworkType: PlaylistArtworkType

  private var playlistManager: PlaylistManager { PlaylistManager.shared }
  private var library: SongLibrary { SongLibrary.shared }

  init(playlist: Playlist) {
    self.playlist = playlist
    _name = State(initialValue: playlist.name)
    _description = State(initialValue: playlist.playlistDescription ?? "")
    _artworkPath = State(initialValue: playlist.artworkPath)
    _artworkType = State(initialValue: playlist.artworkType)
  }

  var body: some View {
    NavigationStack {
      Form {
        artworkTypeMenu

        if artworkType == .custom {
          artworkSelectionSection
        }

        Section("Playlist Info") {
          TextField("Name", text: $name)
          TextField(
            "Description",
            text: $description,
            axis: .vertical
          )
          .lineLimit(3...6)
        }
      }
      .navigationTitle("Edit Playlist")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: selectedPhotoItem) { _, newItem in
        Task {
          if let data = try? await newItem?.loadTransferable(
            type: Data.self
          ) {
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
          Button("Save") {
            Task {
              var customPath = artworkPath
              if let data = artworkData {
                customPath = await library.cacheArtwork(data)
              }

              playlistManager.updatePlaylist(
                playlist,
                name: name,
                description: description.isEmpty
                  ? nil : description
              )

              playlistManager.updatePlaylistArtwork(
                playlist,
                artworkType: artworkType,
                artworkPath: customPath
              )
              dismiss()
            }
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  @ViewBuilder
  private var artworkTypeMenu: some View {

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
    .onChange(of: artworkType) {
      playlistManager.updatePlaylistArtwork(
        playlist,
        artworkType: artworkType
      )
    }
  }

  @ViewBuilder
  private var artworkSelectionSection: some View {
    Section("Artwork") {
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
            if artworkPath != nil || artworkImage != nil {
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
