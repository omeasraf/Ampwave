//
//  NowPlayingArtworkView.swift
//  Ampwave
//
//  Animated artwork view for the now playing screen.
//

internal import SwiftUI

internal struct NowPlayingArtworkView: View {
    @State private var isDragging: Bool = false
    internal var playback: PlaybackController
    
    internal var body: some View {
        Group {
            if let path = playback.currentItem?.artworkPath {
                AlbumArtworkView(artworkPath: path, size: 260)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60, weight: .medium))
                            .foregroundStyle(.secondary)
                    )
                    .frame(width: 260, height: 260)
            }
        }
        .scaleEffect(
            playback.isPlaying ? (isDragging ? 0.98 : 1.0) : (isDragging ? 0.95 : 0.98)
        )
        .animation(
            Animation.interactiveSpring(response: 0.5, dampingFraction: 0.86, blendDuration: 0.17),
            value: playback.isPlaying || isDragging
        )
        .gesture(
            DragGesture()
                .onChanged { _ in
                    isDragging = true
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

#Preview {
    NowPlayingArtworkView(playback: PlaybackController.shared)
}
