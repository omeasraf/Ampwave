//
//  QueueListView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

struct QueueListView: View {
  let artworkColor: Color?
  let songs: [LibrarySong]
  let currentIndex: Int?

  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    if songs.isEmpty {
      ContentUnavailableView(
        "Empty Queue",
        systemImage: "list.bullet",
        description: Text("No songs in queue")
      )
      .frame(minHeight: 200)
      .background(artworkColor)
      .cornerRadius(10)
    } else {
      List {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          HStack {
            SongRow(song: song, isCurrent: false)
            Spacer()
            if let currentIndex = currentIndex, index == currentIndex {
              Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(.pink)
                .symbolEffect(.pulse, options: .repeating)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture {
            playback.playQueue(playback.queue, startingAt: index)
          }
        }
        .onDelete(perform: deleteSongs)
      }
      .listStyle(.plain)
      .frame(minHeight: 200)
      .background(artworkColor)
      .cornerRadius(10)
    }
  }

  private func deleteSongs(at offsets: IndexSet) {
    for index in offsets {
      playback.removeFromQueue(at: index)
    }
  }
}
