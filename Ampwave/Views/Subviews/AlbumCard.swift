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
  var artworkShape: LibraryArtworkShape = .roundedRectangle
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

  /// Caption scales with the cell so a 3-up grid stays legible and a 1-up cell
  /// doesn't leave tiny text stranded under huge artwork.
  private var titleFontSize: CGFloat {
    switch artworkSize {
    case ..<120: return 12
    case ..<240: return 14
    default: return 17
    }
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Square artwork. Fixed to artworkSize so the card has a stable, predictable
      // width in both LazyVGrid columns AND LazyHStack horizontal scrollers.
      // (maxWidth:.infinity caused cards to expand to fill the entire HScrollView.)
      AlbumArtworkView(
        artworkPath: album.artworkPath,
        size: artworkSize,
        // Clamped: a pure percentage radius balloons past the app's 16–20 pt
        // corner language once a cell fills the screen width.
        cornerRadius: artworkShape == .circle
          ? artworkSize / 2
          : (isFullBleed ? 0 : min(20, max(8, artworkSize * 0.08)))
      )
      .accessibilityHidden(true)

      // Text — single line with ellipsis so every card stays the same height.
      VStack(alignment: .leading, spacing: 3) {
        Text(album.name)
          .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(.primary)

        if let artist = album.artist {
          Text(artist)
            .font(.system(size: titleFontSize - 2, weight: .medium))
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

struct AlbumListRow: View {
  let album: Album
  var artworkShape: LibraryArtworkShape = .roundedRectangle

  @State private var isEditingShown = false

  var body: some View {
    NavigationLink(destination: AlbumView(album: album)) {
      HStack(spacing: 14) {
        AlbumArtworkView(
          artworkPath: album.artworkPath,
          size: 64,
          cornerRadius: artworkShape == .circle ? 32 : 10
        )
        VStack(alignment: .leading, spacing: 4) {
          Text(album.name)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(album.artist ?? "Unknown Artist")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.vertical, 9)
    }
    .buttonStyle(.plain)
    .albumContextMenu(album: album) { isEditingShown = true }
    .sheet(isPresented: $isEditingShown) {
      AlbumEditSheet(album: album, isPresented: $isEditingShown)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(album.artist.map { "\(album.name), album by \($0)" } ?? album.name)
    .accessibilityHint("Opens album")
  }
}
