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
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(album.name)
            .font(.headline)
            .lineLimit(1)
            .foregroundStyle(.primary)

          if let artist = album.artist {
            Text(artist)
              .font(.subheadline)
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(albumAccessibilityLabel)
    .accessibilityHint("Opens album")
    .albumContextMenu(album: album) {
      isEditingShown = true
    }
    .sheet(isPresented: $isEditingShown) {
      AlbumEditSheet(album: album, isPresented: $isEditingShown)
    }
  }

  private var albumAccessibilityLabel: String {
    if let artist = album.artist {
      return "\(album.name), album by \(artist)"
    }
    return album.name
  }
}
