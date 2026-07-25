//
//  AlbumCard.swift
//  Ampwave
//
//  Reusable album card — artwork fills the column width, title + artist below.
//
//  Works in both LazyVGrid (grid columns propose a fixed width) and LazyHStack
//  (no width proposed). The key trick: `frame(minWidth: artworkSize, maxWidth: .infinity)`
//  on the clear spacer ensures the card is never 0-wide in horizontal scroll contexts
//  while still expanding to fill whatever the grid column offers.
//

internal import SwiftUI

struct AlbumCard: View {
  let album: Album
  /// Sizing hint used as the minimum card width. Pass the exact column width from
  /// the grid so the GeometryReader reads a stable size; defaults to 160 for
  /// horizontal scroll contexts where no width is proposed.
  var artworkSize: CGFloat = 160
  /// Full-bleed mode: no corner radius, no outer padding (used by large Library grid).
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
    .albumContextMenu(album: album) { isEditingShown = true }
    .sheet(isPresented: $isEditingShown) {
      AlbumEditSheet(album: album, isPresented: $isEditingShown)
    }
  }

  // MARK: - Card layout

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Square artwork. Fixed to artworkSize so the card has a stable, predictable
      // width in both LazyVGrid columns AND LazyHStack horizontal scrollers.
      // (maxWidth:.infinity caused cards to expand to fill the entire HScrollView.)
      AlbumArtworkView(
        artworkPath: album.artworkPath,
        size: artworkSize,
        cornerRadius: isFullBleed ? 0 : max(8, artworkSize * 0.08)
      )
      .accessibilityHidden(true)

      // Text — single line with ellipsis so every card stays the same height.
      VStack(alignment: .leading, spacing: 3) {
        Text(album.name)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .padding(.horizontal, isFullBleed ? 10 : 4)
      .padding(.top, 6)
      .padding(.bottom, isFullBleed ? 10 : 4)
      .frame(width: artworkSize, alignment: .leading)
    }
    // Fixed width ensures the card is the right size in grids AND horizontal scrollers.
    .frame(width: artworkSize, alignment: .leading)
  }

  // MARK: - Accessibility

  private var albumAccessibilityLabel: String {
    if let artist = album.artist {
      return "\(album.name), album by \(artist)"
    }
    return album.name
  }
}
