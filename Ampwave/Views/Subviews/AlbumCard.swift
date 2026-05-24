//
//  AlbumCard.swift
//  Ampwave
//
//  Reusable album card component with context menu.
//

internal import SwiftUI

struct AlbumCard: View {
  let album: Album
  var artworkSize: CGFloat = 180
  /// When true the card is rendered edge-to-edge with no background or padding (large grid mode).
  var isFullBleed: Bool = false

  @Environment(ThemeManager.self) private var themeManager
  @State private var isEditingShown = false

  // Scale inner spacing/fonts for very small thumbnails (small-grid mode)
  private var innerPadding: CGFloat { artworkSize < 100 ? 8 : 12 }
  private var innerSpacing: CGFloat { artworkSize < 100 ? 6 : 12 }
  private var textSpacing: CGFloat { artworkSize < 100 ? 3 : 5 }
  private var titleFontSize: CGFloat { artworkSize < 100 ? 13 : 16 }
  private var subtitleFontSize: CGFloat { artworkSize < 100 ? 11 : 13 }
  private var metaFontSize: CGFloat { artworkSize < 100 ? 10 : 12 }
  private var artworkCornerRadius: CGFloat { max(10, artworkSize * 0.11) }

  var body: some View {
    NavigationLink(destination: AlbumView(album: album)) {
      if isFullBleed {
        fullBleedContent
      } else {
        glassCardContent
      }
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

  // MARK: - Full-bleed (large grid)

  private var fullBleedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      AlbumArtworkView(artworkPath: album.artworkPath, size: artworkSize, cornerRadius: 0)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(album.name)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 10)
    }
    // No glass, no fixed width — fills the column width given by LazyVGrid
  }

  // MARK: - Glass card (medium / small grid)

  private var glassCardContent: some View {
    VStack(alignment: .leading, spacing: innerSpacing) {
      AlbumArtworkView(
        artworkPath: album.artworkPath,
        size: artworkSize,
        cornerRadius: artworkCornerRadius
      )
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: textSpacing) {
        Text(album.name)
          .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
          .lineLimit(2)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: subtitleFontSize, weight: .medium))
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
        .font(.system(size: metaFontSize, weight: .medium))
        .foregroundStyle(.secondary.opacity(0.9))
      }
    }
    .padding(innerPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(
      themeManager.coloredSurfaces ? .regular : .identity,
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
  }

  // MARK: - Accessibility

  private var albumAccessibilityLabel: String {
    if let artist = album.artist {
      return "\(album.name), album by \(artist)"
    }
    return album.name
  }
}
