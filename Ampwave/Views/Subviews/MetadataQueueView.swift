//
//  MetadataQueueView.swift
//  Ampwave
//
//  View for identifying and fixing songs with missing metadata.
//

import SwiftData
internal import SwiftUI

struct MetadataQueueView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @State private var incompleteSongs: [LibrarySong] = []
  @State private var isLoading = true
  @State private var selectedSong: LibrarySong?

  private var library: SongLibrary { SongLibrary.shared }

  var body: some View {
    Group {
      if isLoading {
        ProgressView("Analyzing Library...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if incompleteSongs.isEmpty {
        VStack(spacing: 20) {
          Image(systemName: "sparkles")
            .font(.system(size: 60))
            .foregroundStyle(themeManager.accentColor)
          Text("Everything looks great!")
            .font(.headline)
          Text("All songs in your library have complete metadata.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          Section {
            Text("\(incompleteSongs.count) songs with missing information.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .listRowBackground(Color.clear)

          ForEach(incompleteSongs) { song in
            IncompleteSongRow(song: song) {
              selectedSong = song
            }
            .listRowBackground(themeManager.cardBackgroundColor)
          }
        }
        .listStyle(.insetGrouped)
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle("Missing Metadata")
    .onAppear {
      refreshQueue()
    }
    .sheet(item: $selectedSong) { song in
      SongEditSheet(
        song: song,
        isPresented: Binding(
          get: { selectedSong != nil },
          set: {
            if !$0 {
              selectedSong = nil
              refreshQueue()
            }
          }
        ))
    }
  }

  private func refreshQueue() {
    isLoading = true
    Task {
      let songs = await Task.detached {
        return SongLibrary.shared.songs.filter { song in
          let isGeneric = song.album == "Unknown Album" || song.artist == "Unknown Artist"
          let isMissingInfo =
            song.artworkPath == nil || song.genre == nil || song.year == nil || song.year == 0
          return isGeneric || isMissingInfo
        }
      }.value

      await MainActor.run {
        self.incompleteSongs = songs
        self.isLoading = false
      }
    }
  }
}

struct IncompleteSongRow: View {
  let song: LibrarySong
  let action: () -> Void
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if let path = song.effectiveArtworkPath, let url = PathManager.resolve(path) {
          #if os(iOS)
            if let uiImage = UIImage(contentsOfFile: url.path) {
              Image(uiImage: uiImage)
                .resizable()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
          #endif
        } else {
          RoundedRectangle(cornerRadius: 6)
            .fill(.secondary.opacity(0.2))
            .frame(width: 50, height: 50)
            .overlay {
              Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(song.title)
            .font(.headline)
            .lineLimit(1)

          Text(song.artist)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)

          HStack {
            if song.artworkPath == nil {
              badge("No Art")
            }
            if song.album == "Unknown Album" {
              badge("No Album")
            }
            if song.genre == nil {
              badge("No Genre")
            }
            if song.year == nil || song.year == 0 {
              badge("No Year")
            }
          }
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
  }

  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 8, weight: .bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.red.opacity(0.1))
      .foregroundStyle(.red)
      .clipShape(Capsule())
  }
}
