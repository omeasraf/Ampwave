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

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationLink(destination: AlbumView(album: album)) {
      VStack(alignment: .leading, spacing: 10) {
        AlbumArtworkView(artworkPath: album.artworkPath, size: 140)
          .clipShape(RoundedRectangle(cornerRadius: 10))

        VStack(alignment: .leading, spacing: 4) {
          Text(album.name)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(.primary)

          if let artist = album.artist {
            Text(artist)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
      }
      .frame(width: 140)
      .background(themeManager.cardBackgroundColor)
      .clipShape(RoundedRectangle(cornerRadius: 12))
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
