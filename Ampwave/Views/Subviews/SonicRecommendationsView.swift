internal import SwiftUI

/// Reusable recommendation shelf for the player. PlaylistView uses native List
/// rows so its add controls and swipe behavior remain consistent with playlists.
struct SonicRecommendationsView: View {
  let songs: [LibrarySong]
  let isLoading: Bool
  let onRefresh: () -> Void
  let onSelect: (LibrarySong) -> Void

  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("More Like This", systemImage: "waveform.path")
          .font(.title3.bold())
        Spacer()
        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Refresh More Like This")
      }

      if isLoading && songs.isEmpty {
        HStack(spacing: 10) {
          ProgressView()
          Text("Matching the sound of this song…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
      } else if songs.isEmpty {
        Text("No matching songs are available yet.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        VStack(spacing: 0) {
          ForEach(songs.prefix(8)) { song in
            Button { onSelect(song) } label: {
              HStack(spacing: 12) {
                ArtworkImageView(artworkPath: song.effectiveArtworkPath, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                  Text(song.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                  Text(song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                  .foregroundStyle(themeManager.accentColor)
              }
              .contentShape(Rectangle())
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if song.id != songs.prefix(8).last?.id {
              Divider().padding(.leading, 70)
            }
          }
        }
        .background(themeManager.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 20))
      }
    }
  }
}
