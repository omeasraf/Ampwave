//
//  ArtistCard.swift
//  Ampwave
//
//  Reusable artist card component.
//

internal import SwiftUI

struct ArtistCard: View {
  @Environment(ThemeManager.self) private var themeManager
  let artist: Artist

  var body: some View {
    NavigationLink(destination: ArtistView(artist: artist)) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Spacer()
          ArtistImageView(artworkPath: artist.artworkPath, size: 140)
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
          Spacer()
        }
        .padding(.top, 8)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text(artist.name)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.primary)

          Text("\(artist.songCount) songs")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
      }
      .padding(12)
      .frame(width: 174, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(cardBackground)
          .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .stroke(.white.opacity(0.06), lineWidth: 1)
          }
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(artist.name), \(artist.songCount) songs")
    .accessibilityHint("Opens artist")
  }

  private var cardBackground: some ShapeStyle {
    LinearGradient(
      colors: [
        themeManager.cardBackgroundColor.opacity(0.94),
        themeManager.backgroundColor.opacity(0.82),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}
