//
//  QueueListView.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

internal import SwiftUI

struct QueueSheetView: View {
  @Environment(\.dismiss) private var dismiss
  private var playback: PlaybackController { PlaybackController.shared }

  var body: some View {
    NavigationStack {
      List {
        if let current = playback.currentItem {
          Section("Now Playing") {
            SongRow(song: current, isCurrent: true)
          }
        }

        if !playback.upNext.isEmpty {
          Section("Up Next") {
            ForEach(Array(playback.upNext.enumerated()), id: \.element.id) { index, song in
              SongRow(song: song, isCurrent: false)
                .contentShape(Rectangle())
                .onTapGesture {
                  playFromUpNext(at: index)
                }
            }
            .onDelete(perform: removeSongs)
            .onMove(perform: moveSongs)
          }
        }

        if !playback.previouslyPlayed.isEmpty {
          Section("History") {
            ForEach(playback.previouslyPlayed.reversed()) { song in
              SongRow(song: song, isCurrent: false)
                .opacity(0.6)
            }
          }
        }
      }
      .navigationTitle("Queue")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          EditButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
    }
  }

  private func playFromUpNext(at index: Int) {
    // Calculate the actual index in the full queue
    // playback.upNext is queue[(currentQueueIndex + 1)...]
    let actualIndex = playback.currentQueueIndex + 1 + index

    // Jump to this song in the existing queue
    playback.jumpToQueueIndex(actualIndex)
  }

  private func removeSongs(at offsets: IndexSet) {
    for index in offsets {
      // The offset is relative to upNext, so we add currentQueueIndex + 1
      let actualIndex = playback.currentQueueIndex + 1 + index
      playback.removeFromQueue(at: actualIndex)
    }
  }

  private func moveSongs(from source: IndexSet, to destination: Int) {
    // Convert relative offsets to absolute queue indices
    // We must be careful with how SwiftUI's move works with absolute indices
    let offset = playback.currentQueueIndex + 1

    for sourceIndex in source {
      let actualSource = offset + sourceIndex
      let actualDestination = offset + (destination > sourceIndex ? destination - 1 : destination)
      playback.moveSong(from: actualSource, to: actualDestination)
    }
  }
}
