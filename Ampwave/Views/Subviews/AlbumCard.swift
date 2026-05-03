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
      VStack(alignment: .leading, spacing: 12) {
        AlbumArtworkView(artworkPath: album.artworkPath, size: 160)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text(album.name)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .foregroundStyle(.primary)

          if let artist = album.artist {
            Text(artist)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          HStack(spacing: 6) {
            Text("\(album.songCount) songs")
            if let year = album.year {
              Text("•")
              Text(String(year))
            }
          }
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary.opacity(0.9))
        }
      }
      .padding(12)
      .frame(width: 184, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .stroke(.white.opacity(0.06), lineWidth: 1)
          }
      )
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
