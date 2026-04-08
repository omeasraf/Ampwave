//
//  AlbumCard.swift
//  Ampwave
//
//  Reusable album card component with context menu.
//

internal import SwiftUI

struct AlbumCard: View {
  let album: Album

  @State private var isEditingShown = false

  var body: some View {
    NavigationLink(destination: AlbumView(album: album)) {
      VStack(alignment: .leading, spacing: 8) {
        AlbumArtworkView(artworkPath: album.artworkPath, size: 140, icon: nil)

        VStack(alignment: .leading, spacing: 2) {
          Text(album.name)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)

          if let year = album.year {
            Text("\(year)")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 140, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .albumContextMenu(album: album) {
      isEditingShown = true
    }
    .sheet(isPresented: $isEditingShown) {
      AlbumEditSheet(album: album, isPresented: $isEditingShown)
    }
  }
}
