//
//  WatchNowPlayingView.swift
//  Ampwave Watch App
//

internal import SwiftUI

struct WatchNowPlayingView: View {
    @State private var playbackManager = WatchPlaybackManager.shared
    @State private var showLyrics = false
    
    var body: some View {
        VStack {
            // Header
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(.accentColor)
                Text("iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Artwork & Info
            VStack {
                if !playbackManager.remoteStatus.title.isEmpty {
                    remoteArtworkAndInfo
                } else {
                    noPlaybackView
                }
            }
            
            Spacer()
            
            // Progress Bar
            playbackProgress
            
            // Controls
            HStack(spacing: 20) {
                Button(action: {
                    playbackManager.previousTrack()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    playbackManager.togglePlayback()
                }) {
                    Image(systemName: playbackManager.remoteStatus.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .padding()
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    playbackManager.nextTrack()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            HStack {
                Button(action: {
                    showLyrics.toggle()
                }) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(showLyrics ? .accentColor : .primary)
                .disabled(playbackManager.remoteStatus.title.isEmpty)
                
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding()
        .sheet(isPresented: $showLyrics) {
            Text("Lyrics available on iPhone")
        }
    }
    
    private var noPlaybackView: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 60, height: 60)
                Image(systemName: "music.note.slash")
                    .font(.title)
                    .foregroundColor(.gray)
            }
            
            Text("Not Playing")
                .font(.headline)
            Text("Select music on Watch or iPhone")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var remoteArtworkAndInfo: some View {
        VStack {
            if let songId = playbackManager.remoteStatus.songId {
                let artworkName = "\(songId.uuidString)_artwork.jpg"
                let url = getDocumentsDirectory().appendingPathComponent(artworkName)
                
                if FileManager.default.fileExists(atPath: url.path),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                } else {
                    genericRemoteArtwork
                }
            } else {
                genericRemoteArtwork
            }
            
            Text(playbackManager.remoteStatus.title)
                .font(.headline)
                .lineLimit(1)
            Text(playbackManager.remoteStatus.artist)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
    
    private var genericRemoteArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 60, height: 60)
            Image(systemName: "iphone")
                .font(.title)
                .foregroundColor(.accentColor)
        }
    }
    
    private var playbackProgress: some View {
        let current = playbackManager.remoteStatus.currentTime
        let total = playbackManager.remoteStatus.duration
        
        return VStack(spacing: 2) {
            ProgressView(value: total > 0 ? current / total : 0)
                .tint(.accentColor)
            
            HStack {
                Text(formatTime(current))
                    .font(.system(size: 8, design: .monospaced))
                Spacer()
                Text(formatTime(total))
                    .font(.system(size: 8, design: .monospaced))
            }
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
