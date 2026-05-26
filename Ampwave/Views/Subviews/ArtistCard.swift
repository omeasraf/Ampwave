//
//  ArtistCard.swift
//  Ampwave
//
//  Reusable artist card — Apple Music–style: circular artwork fills the column
//  with a small horizontal inset, name + song count centred below.
//

internal import SwiftUI

struct ArtistCard: View {
  let artist: Artist
  /// Sizing hint; the actual display fills the grid column width.
  var artworkSize: CGFloat = 150

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      VStack(alignment: .center, spacing: 0) {
        // Circular artwork fills the column.  A small horizontal inset keeps
        // the circle from touching the grid gutter.
        Color.clear
          .aspectRatio(1, contentMode: .fit)
          .padding(.horizontal, 6)
          .overlay {
            GeometryReader { geo in
              let d = geo.size.width
              ArtistImageView(artworkPath: artist.artworkPath, size: d)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }
          }
          .accessibilityHidden(true)

        // Text centred below the circle
        VStack(alignment: .center, spacing: 2) {
          Text(artist.name)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)

          Text("\(artist.songCount) songs")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
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
