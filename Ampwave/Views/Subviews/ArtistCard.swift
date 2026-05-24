//
//  ArtistCard.swift
//  Ampwave
//
//  Reusable artist card component.
//

internal import SwiftUI

struct ArtistCard: View {
  let artist: Artist
  var artworkSize: CGFloat = 150

  @Environment(ThemeManager.self) private var themeManager

  private var isCompact: Bool { artworkSize < 130 }
  private var innerPadding: CGFloat { isCompact ? 8 : 12 }
  private var innerSpacing: CGFloat { isCompact ? 8 : 12 }
  private var textSpacing: CGFloat { isCompact ? 3 : 5 }
  private var titleFontSize: CGFloat { max(13, artworkSize * 0.105) }
  private var subtitleFontSize: CGFloat { max(11, artworkSize * 0.085) }

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      VStack(alignment: .leading, spacing: innerSpacing) {
        HStack {
          Spacer()
          ArtistImageView(artworkPath: artist.artworkPath, size: artworkSize)
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
          Spacer()
        }
        .padding(.top, isCompact ? 4 : 8)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: textSpacing) {
          Text(artist.name)
            .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.primary)

          Text("\(artist.songCount) songs")
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
      }
      .padding(innerPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassEffect(
        themeManager.coloredSurfaces ? .regular : .identity,
        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(artist.name), \(artist.songCount) songs")
    .accessibilityHint("Opens artist")
  }
}
