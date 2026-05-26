//
//  CreateSmartPlaylistSheet.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct CreateSmartPlaylistSheet: View {
  @State private var name = ""
  @State private var description = ""
  @State private var createdPlaylist: Playlist?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  var body: some View {
    if let playlist = createdPlaylist {
      SmartPlaylistRulesSheet(playlist: playlist)
    } else {
      NavigationStack {
        Form {
          Section("Playlist Info") {
            TextField("Name", text: $name)
            TextField("Description (Optional)", text: $description)
          }

          Section {
            Text("After naming your playlist, you'll define the rules that automatically populate it with matching songs.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .navigationTitle("New Smart Playlist")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Next") {
              createAndContinue()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      }
    }
  }

  private func createAndContinue() {
    let emptyRules = SmartPlaylistRules(
      rules: [], limitEnabled: false, limitCount: 25, limitBy: .random)
    if let playlist = playlistManager.createSmartPlaylist(
      name: name.trimmingCharacters(in: .whitespaces),
      description: description.isEmpty ? nil : description,
      rules: emptyRules
    ) {
      createdPlaylist = playlist
    }
  }
}
