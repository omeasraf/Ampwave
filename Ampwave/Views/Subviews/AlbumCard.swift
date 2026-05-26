//
//  AlbumCard.swift
//  Ampwave
//
//  Reusable album card — Apple Music–style: artwork fills the column,
//  title + artist text sits directly below, no glass card container.
//

internal import SwiftUI

struct AlbumCard: View {
  let album: Album
  /// Hint for the artwork corner radius when used in contexts without a grid.
  var artworkSize: CGFloat = 180
  /// In full-bleed (large grid) mode the artwork has no corner radius and no extra padding.
  var isFullBleed: Bool = false

  @Environment(ThemeManager.self) private var themeManager
  @State private var isEditingShown = false

  var body: some View {
    NavigationLink(destination: AlbumView(album: album)) {
      cardContent
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

  // MARK: - Card layout

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Square artwork that fills the full column width.
      // `Color.clear.aspectRatio(1, .fit)` accepts the width proposed by the
      // flexible grid column and constrains height to match.  The overlay then
      // passes that exact size to AlbumArtworkView via GeometryReader.
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          GeometryReader { geo in
            let w = geo.size.width
            AlbumArtworkView(
              artworkPath: album.artworkPath,
              size: w,
              cornerRadius: isFullBleed ? 0 : max(8, w * 0.1)
            )
          }
        }
        .accessibilityHidden(true)

      // Text sits directly below the artwork with a small gap.
      VStack(alignment: .leading, spacing: 3) {
        Text(album.name)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .lineLimit(2)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, isFullBleed ? 10 : 4)
      .padding(.top, 7)
      .padding(.bottom, isFullBleed ? 10 : 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Accessibility

  private var albumAccessibilityLabel: String {
    if let artist = album.artist {
      return "\(album.name), album by \(artist)"
    }
    return album.name
  }
}
