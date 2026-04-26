//
//  MacOSLyricsWindowView.swift
//  Ampwave
//
//  A floating, utility-style window for displaying lyrics on macOS.
//

internal import SwiftUI

struct MacOSLyricsWindowView: View {
    @Environment(\.dismiss) private var dismiss
    private var playback: PlaybackController { PlaybackController.shared }
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .top) {
            // Main Content
            VStack(spacing: 0) {
                // Song Info Header
                if let item = playback.currentItem {
                    HStack(spacing: 16) {
                        FixedArtworkThumbnail(artworkPath: item.artworkPath, size: 48)
                            .cornerRadius(6)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40) // Space for custom title bar
                    .padding(.bottom, 20)
                    .background(Color.primary.opacity(0.03))
                }
                
                // Lyrics - now should scroll freely
                ExpandedLyricsView(isExpanded: .constant(true))
            }
            .background(.ultraThinMaterial)
            
            // Custom PiP Title Bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                
                Spacer()
                
                if let item = playback.currentItem {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Placeholder to balance the close button
                Color.clear.frame(width: 30)
            }
            .frame(height: 32)
            .background(Color.black.opacity(0.1))
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
        }
        .frame(minWidth: 350, minHeight: 450)
        .onHover { hovering in
            isHovering = hovering
        }
        #if os(macOS)
        .onAppear {
            // Safer way to find the window this view is in
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.title == "Lyrics" }) ?? NSApplication.shared.windows.last {
                    window.level = .floating
                    window.isMovableByWindowBackground = true
                }
            }
        }
        #endif
    }
}

#Preview {
    MacOSLyricsWindowView()
}
