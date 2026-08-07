//
//  CreateSmartPlaylistSheet.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

/// Two-step smart playlist creation: name, then rules.
///
/// The playlist is only committed once the rules are confirmed. Creating it up
/// front left an orphan behind whenever the rules step was cancelled — and
/// since a rule-less smart playlist matched everything, that orphan came
/// pre-filled with the entire library.
struct CreateSmartPlaylistSheet: View {
  @State private var name = ""
  @State private var description = ""
  @State private var showingRules = false

  @Environment(\.dismiss) private var dismiss

  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Playlist Info") {
          TextField("Name", text: $name)
          TextField("Description (Optional)", text: $description)
        }

        Section {
          Text(
            "After naming your playlist, you'll define the rules that automatically populate it with matching songs."
          )
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
          Button("Next") { showingRules = true }
            .disabled(trimmedName.isEmpty)
        }
      }
      .navigationDestination(isPresented: $showingRules) {
        SmartRulesEditor(
          initialRules: SmartPlaylistRules(
            rules: [], limitEnabled: false, limitCount: 25, limitBy: .random),
          title: trimmedName.isEmpty ? "Smart Rules" : trimmedName,
          confirmTitle: "Create",
          onCancel: { showingRules = false },
          onSave: { rules in
            _ = playlistManager.createSmartPlaylist(
              name: trimmedName,
              description: description.isEmpty ? nil : description,
              rules: rules
            )
            dismiss()
          }
        )
      }
    }
  }
}
