//
//  ArtistCard.swift
//  Ampwave
//
//  Reusable artist card — circular artwork fills the column width (with a small
//  inset), name + song count centred below.
//
//  The horizontal inset is applied by reducing the size passed to ArtistImageView
//  rather than padding Color.clear before the overlay. Padding the spacer before
//  the overlay causes GeometryReader to measure the padded (larger) frame and
//  render the circle at full width, making it overlap the text section below.
//

internal import SwiftUI

struct ArtistCard: View {
  let artist: Artist
  /// Minimum card width; used as a fallback when no width is proposed (e.g. LazyHStack).
  var artworkSize: CGFloat = 150

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      VStack(alignment: .center, spacing: 8) {   // explicit 8 pt gap — not 0 + padding

        // Circular artwork.
        // Same minWidth/maxWidth pattern as AlbumCard so the card has a valid
        // size in both grid columns and horizontal scroll containers.
        // The inset (6 pt each side) is applied by scaling the diameter to
        // `geo.size.width - 12` instead of padding the spacer, which keeps the
        // GeometryReader measurement clean and prevents overflow into the text.
        Color.clear
          .frame(minWidth: artworkSize, maxWidth: .infinity)
          .aspectRatio(1, contentMode: .fit)
          .overlay {
            GeometryReader { geo in
              let inset: CGFloat = 6
              let d = max(0, geo.size.width - inset * 2)
              ArtistImageView(artworkPath: artist.artworkPath, size: d)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .frame(width: geo.size.width, height: geo.size.height)  // center in full frame
            }
          }
          .accessibilityHidden(true)

        // Name + song count — always one line to keep all cards the same height.
        VStack(alignment: .center, spacing: 2) {
          Text(artist.name)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)

          Text("\(artist.songCount) songs")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(artist.name), \(artist.songCount) songs")
    .accessibilityHint("Opens artist")
  }
}
