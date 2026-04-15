//
//  WatchLyricsView.swift
//  Ampwave Watch App
//

internal import SwiftUI
import SwiftData

struct WatchLyricsView: View {
    @State private var playbackManager = WatchPlaybackManager.shared
    @State private var lines: [LyricLine] = []
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lines.isEmpty {
                        VStack {
                            Text("No lyrics available")
                                .foregroundColor(.secondary)
                            Text("Try starting playback on iPhone")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    } else {
                        ForEach(lines, id: \.self) { line in
                            Text(line.text)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(isCurrent(line) ? .accentColor : .primary.opacity(0.6))
                                .scaleEffect(isCurrent(line) ? 1.05 : 1.0)
                                .animation(.spring(), value: playbackManager.remoteStatus.currentTime)
                                .id(line)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: playbackManager.remoteStatus.currentTime) { _, newValue in
                if let currentLine = lines.last(where: { $0.timestamp <= newValue }) {
                    withAnimation {
                        proxy.scrollTo(currentLine, anchor: .center)
                    }
                }
            }
        }
        .onAppear {
            updateLyrics()
        }
        .onChange(of: playbackManager.remoteStatus.songId) {
            updateLyrics()
        }
    }
    
    private func updateLyrics() {
        guard let songId = playbackManager.remoteStatus.songId else {
            lines = []
            return
        }
        
        // Use the shared model context from WatchSyncManager
        guard let context = WatchSyncManager.shared.modelContext else {
            lines = []
            return
        }
        
        let descriptor = FetchDescriptor<LibrarySong>(predicate: #Predicate { $0.id == songId })
        if let song = try? context.fetch(descriptor).first, let lyrics = song.lyrics {
            lines = LRCParser.parse(lyrics)
        } else {
            lines = []
        }
    }
    
    private func isCurrent(_ line: LyricLine) -> Bool {
        guard let index = lines.firstIndex(of: line) else { return false }
        let nextTimestamp = index + 1 < lines.count ? lines[index + 1].timestamp : Double.infinity
        let currentTime = playbackManager.remoteStatus.currentTime
        return currentTime >= line.timestamp && currentTime < nextTimestamp
    }
}
