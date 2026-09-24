//
//  ArtistCard.swift
//  Ampwave
//
//  Reusable artist card — configurable artwork fills the column width (with a small
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
  var artworkShape: LibraryArtworkShape = .roundedRectangle

  @Environment(ThemeManager.self) private var themeManager

  /// Matches AlbumCard's caption scale so the Albums and Artists grids read as
  /// the same grid at the same density.
  private var titleFontSize: CGFloat {
    switch artworkSize {
    case ..<120: return 12
    case ..<240: return 14
    default: return 17
    }
  }

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      VStack(alignment: .center, spacing: 8) {   // explicit 8 pt gap — not 0 + padding

        // Artist artwork using the user's rounded-square or circular preference.
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
              ArtistImageView(
                artworkPath: artist.artworkPath,
                size: d,
                shape: artworkShape
              )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .frame(width: geo.size.width, height: geo.size.height)  // center in full frame
            }
          }
          .accessibilityHidden(true)

        // Name + song count — always one line to keep all cards the same height.
        VStack(alignment: .center, spacing: 2) {
          Text(artist.name)
            .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)

          Text("\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")")
            .font(.system(size: titleFontSize - 2, weight: .medium))
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

struct ArtistListRow: View {
  let artist: Artist
  var artworkShape: LibraryArtworkShape = .roundedRectangle

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      HStack(spacing: 14) {
        ArtistImageView(
          artworkPath: artist.artworkPath,
          size: 64,
          shape: artworkShape
        )
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)

        VStack(alignment: .leading, spacing: 4) {
          Text(artist.name)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(artistSummary)
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(artist.name), \(artistSummary)")
    .accessibilityHint("Opens artist")
  }

  private var artistSummary: String {
    let songs = "\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")"
    guard artist.albumCount > 0 else { return songs }
    let albums = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")"
    return "\(albums) • \(songs)"
  }
}
