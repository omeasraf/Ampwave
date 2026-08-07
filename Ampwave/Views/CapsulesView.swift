//
//  CapsulesView.swift
//  Ampwave
//
//  Create, browse, play, import, and share personal offline mixtapes.
//

import SwiftData
internal import SwiftUI
import UniformTypeIdentifiers

struct CapsulesListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @Query(sort: \AmpwaveCapsule.createdDate, order: .reverse)
  private var capsules: [AmpwaveCapsule]

  @State private var isImporting = false
  @State private var isProcessingImport = false
  @State private var importError: String?

  private var library: SongLibrary { SongLibrary.shared }

  var body: some View {
    List {
      ForEach(capsules) { capsule in
        NavigationLink {
          CapsuleDetailView(capsule: capsule)
        } label: {
          CapsuleRow(capsule: capsule)
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }
      .onDelete(perform: deleteCapsules)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .navigationTitle("Capsules")
    .overlay {
      if isProcessingImport {
        ProgressView("Importing Capsule…")
          .padding(20)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      } else if capsules.isEmpty {
        ContentUnavailableView {
          Label {
            Text("No Capsules Yet")
          } icon: {
            Image("ampwave.capsule")
          }
        } description: {
          Text("A Capsule is a personal mixtape with its own note and intentional song order. Create one from any playlist.")
        } actions: {
          Button("Import Capsule") { isImporting = true }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { isImporting = true } label: {
          Label("Import Capsule", systemImage: "square.and.arrow.down")
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [CapsulePackage.contentType],
      allowsMultipleSelection: false
    ) { result in
      importCapsule(result)
    }
    .alert("Couldn't Import Capsule", isPresented: importAlertBinding) {
      Button("OK") { importError = nil }
    } message: {
      Text(importError ?? "The Capsule could not be opened.")
    }
  }

  private var importAlertBinding: Binding<Bool> {
    Binding(
      get: { importError != nil },
      set: { if !$0 { importError = nil } }
    )
  }

  private func deleteCapsules(at offsets: IndexSet) {
    for index in offsets {
      modelContext.delete(capsules[index])
    }
    try? modelContext.save()
  }

  private func importCapsule(_ result: Result<[URL], Error>) {
    Task { @MainActor in
      isProcessingImport = true
      defer { isProcessingImport = false }
      do {
        let urls = try result.get()
        guard let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        _ = try await CapsulePackage.importCapsule(
          from: url,
          into: modelContext,
          library: library
        )
      } catch {
        importError = error.localizedDescription
      }
    }
  }
}

private struct CapsuleRow: View {
  let capsule: AmpwaveCapsule
  private var library: SongLibrary { SongLibrary.shared }

  var body: some View {
    let songs = capsule.resolvedSongs(in: library)
    HStack(spacing: 12) {
      CapsuleArtwork(songs: songs, size: 60)

      VStack(alignment: .leading, spacing: 3) {
        Text(capsule.title)
          .font(.system(size: 16, weight: .semibold))
          .lineLimit(1)
        Text(capsuleSubtitle(resolvedCount: songs.count))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func capsuleSubtitle(resolvedCount: Int) -> String {
    let songText = "\(resolvedCount) song\(resolvedCount == 1 ? "" : "s")"
    if let creator = capsule.creatorName, !creator.isEmpty {
      return "By \(creator) · \(songText)"
    }
    return songText
  }
}

struct CreateCapsuleSheet: View {
  let playlist: Playlist

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @State private var title: String
  @State private var creatorName = ""
  @State private var capsuleDescription = ""
  @State private var personalMessage = ""
  @State private var playExactlyAsCreated = true
  @State private var saveError: String?

  init(playlist: Playlist) {
    self.playlist = playlist
    _title = State(initialValue: playlist.name)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("A Capsule is a personal mixtape saved separately from its source playlist. It keeps your note and intended song order.")
            .font(.subheadline)
          Text("Sharing creates one compressed .ampcap file containing the Capsule information and copies of its audio files.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
          Text("What Is a Capsule?")
        }

        Section("Capsule") {
          TextField("Title", text: $title)
          TextField("Your Name (Optional)", text: $creatorName)
          TextField("Short Description (Optional)", text: $capsuleDescription, axis: .vertical)
            .lineLimit(2...4)
        }

        Section("Message") {
          TextField("Write something for the listener…", text: $personalMessage, axis: .vertical)
            .lineLimit(4...8)
        }

        Section("Playback") {
          Toggle("Play Exactly as Created", isOn: $playExactlyAsCreated)
          Text("Preserves your playlist order so the Capsule unfolds exactly as you intended.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Included Music") {
          LabeledContent("Songs", value: "\(playlist.songCount)")
          LabeledContent("Length", value: formattedDuration(playlist.totalDuration))
          LabeledContent("Approx. Export Size", value: estimatedExportSize)
          Text("Exporting includes copies of these audio files, so the resulting .ampcap file may be large.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Create Capsule")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { createCapsule() }
            .disabled(trimmedTitle.isEmpty || playlist.orderedSongs.isEmpty)
        }
      }
      .alert("Couldn't Create Capsule", isPresented: saveAlertBinding) {
        Button("OK") { saveError = nil }
      } message: {
        Text(saveError ?? "The Capsule could not be saved.")
      }
    }
    .presentationDetents([.large])
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var saveAlertBinding: Binding<Bool> {
    Binding(
      get: { saveError != nil },
      set: { if !$0 { saveError = nil } }
    )
  }

  private func createCapsule() {
    let capsule = AmpwaveCapsule(
      title: trimmedTitle,
      description: optional(capsuleDescription),
      personalMessage: optional(personalMessage),
      creatorName: optional(creatorName),
      sourcePlaylistID: playlist.id,
      songIDs: playlist.orderedSongs.map(\.id),
      playExactlyAsCreated: playExactlyAsCreated
    )
    modelContext.insert(capsule)
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.delete(capsule)
      saveError = error.localizedDescription
    }
  }

  private func optional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func formattedDuration(_ duration: TimeInterval) -> String {
    let minutes = max(0, Int(duration) / 60)
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
  }

  private var estimatedExportSize: String {
    let bytes = playlist.orderedSongs.reduce(Int64(0)) { $0 + Int64($1.size) }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct CapsuleDetailView: View {
  let capsule: AmpwaveCapsule

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @State private var shareURL: URL?
  @State private var showingDeleteConfirmation = false
  @State private var showingEditSheet = false
  @State private var convertedPlaylistName: String?
  @State private var isEditingTrackOrder = false
  @State private var isPreparingShare = false
  @State private var exportError: String?

  private var library: SongLibrary { SongLibrary.shared }
  private var playback: PlaybackController { PlaybackController.shared }
  private var songs: [LibrarySong] { capsule.resolvedSongs(in: library) }

  var body: some View {
    List {
      Section {
        header
      }
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)

      if let message = capsule.personalMessage, !message.isEmpty {
        Section("A Note for You") {
          Text(message)
            .font(.body)
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      }

      Section("Sharing") {
        if isPreparingShare {
          ProgressView("Compressing audio…")
        } else {
          Text("Sharing creates a self-contained .ampcap archive with the Capsule information and every audio file.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          LabeledContent("Approx. Size", value: estimatedExportSize)
        }
      }
      .listRowBackground(themeManager.cardBackgroundColor)

      Section("Track List") {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          SongRow(song: song, isCurrent: playback.currentItem?.id == song.id)
            .contentShape(Rectangle())
            .onTapGesture {
              playback.playQueue(songs, startingAt: index, from: .playlist)
            }
        }
        .onDelete(perform: removeSongs)
        .onMove(perform: moveSongs)
      }
      .listRowBackground(themeManager.cardBackgroundColor)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .navigationTitle(capsule.title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .environment(\.editMode, .constant(isEditingTrackOrder ? .active : .inactive))
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button { showingEditSheet = true } label: {
            Label("Edit Capsule", systemImage: "pencil")
          }
          Button { isEditingTrackOrder.toggle() } label: {
            Label(
              isEditingTrackOrder ? "Done Editing Tracks" : "Edit Track Order",
              systemImage: isEditingTrackOrder ? "checkmark" : "arrow.up.arrow.down"
            )
          }
          Button { convertToPlaylist() } label: {
            Label("Convert to Playlist", systemImage: "text.badge.plus")
          }
          if let shareURL {
            ShareLink(
              item: shareURL,
              subject: Text(capsule.title),
              message: Text("A self-contained Ampwave Capsule with its music included."),
              preview: SharePreview(capsule.title, icon: Image("ampwave.capsule"))
            ) {
              Label("Share .ampcap File…", systemImage: "square.and.arrow.up")
            }
          } else {
            Button { prepareForSharing() } label: {
              Label(
                isPreparingShare ? "Preparing Capsule…" : "Prepare for Sharing",
                systemImage: "archivebox"
              )
            }
            .disabled(isPreparingShare)
          }
          Divider()
          Button(role: .destructive) { showingDeleteConfirmation = true } label: {
            Label("Delete Capsule", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .onChange(of: capsule.lastModifiedDate) { _, _ in shareURL = nil }
    .sheet(isPresented: $showingEditSheet) {
      EditCapsuleSheet(capsule: capsule)
    }
    .alert("Delete Capsule?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        modelContext.delete(capsule)
        try? modelContext.save()
        dismiss()
      }
    } message: {
      Text("The original playlist and music files will not be changed.")
    }
    .alert("Playlist Created", isPresented: playlistCreatedBinding) {
      Button("OK") { convertedPlaylistName = nil }
    } message: {
      Text("“\(convertedPlaylistName ?? capsule.title)” is now available in Playlists.")
    }
    .alert("Couldn't Export Capsule", isPresented: exportAlertBinding) {
      Button("OK") { exportError = nil }
    } message: {
      Text(exportError ?? "The Capsule could not be prepared.")
    }
  }

  private var header: some View {
    VStack(spacing: 16) {
      CapsuleArtwork(songs: songs, size: 210)
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)

      VStack(spacing: 5) {
        Text(capsule.title)
          .font(.title2.bold())
          .multilineTextAlignment(.center)
        if let creator = capsule.creatorName, !creator.isEmpty {
          Text("Made by \(creator)")
            .foregroundStyle(.secondary)
        }
        if let description = capsule.capsuleDescription, !description.isEmpty {
          Text(description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }

      Button {
        playback.shuffleMode = capsule.playExactlyAsCreated ? .off : playback.shuffleMode
        playback.playQueue(songs, from: .playlist)
      } label: {
        Label("Play Capsule", systemImage: "play.fill")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(maxWidth: 240)
          .padding(.vertical, 12)
          .background(themeManager.accentColor)
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(songs.isEmpty)

      Text("\(songs.count) song\(songs.count == 1 ? "" : "s") · \(formattedDuration)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private var formattedDuration: String {
    let minutes = Int(capsule.totalDuration(in: library)) / 60
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
  }

  private var estimatedExportSize: String {
    let bytes = songs.reduce(Int64(0)) { $0 + Int64($1.size) }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private var playlistCreatedBinding: Binding<Bool> {
    Binding(
      get: { convertedPlaylistName != nil },
      set: { if !$0 { convertedPlaylistName = nil } }
    )
  }

  private var exportAlertBinding: Binding<Bool> {
    Binding(
      get: { exportError != nil },
      set: { if !$0 { exportError = nil } }
    )
  }

  private func convertToPlaylist() {
    guard !songs.isEmpty else { return }
    let name = capsule.title
    guard PlaylistManager.shared.createPlaylist(
      name: name,
      description: capsule.capsuleDescription,
      songs: songs
    ) != nil else { return }
    convertedPlaylistName = name
  }

  private func removeSongs(at offsets: IndexSet) {
    let removedIDs = Set(offsets.map { songs[$0].id })
    capsule.songIDs.removeAll { removedIDs.contains($0) }
    saveTrackChanges()
  }

  private func moveSongs(from source: IndexSet, to destination: Int) {
    var resolvedIDs = songs.map(\.id)
    resolvedIDs.move(fromOffsets: source, toOffset: destination)
    let resolvedSet = Set(resolvedIDs)
    let unresolvedIDs = capsule.songIDs.filter { !resolvedSet.contains($0) }
    capsule.songIDs = resolvedIDs + unresolvedIDs
    saveTrackChanges()
  }

  private func saveTrackChanges() {
    capsule.lastModifiedDate = .now
    try? modelContext.save()
  }

  private func prepareForSharing() {
    guard !isPreparingShare else { return }
    isPreparingShare = true
    Task { @MainActor in
      defer { isPreparingShare = false }
      do {
        shareURL = try await CapsulePackage.writeToTemporaryFile(
          capsule: capsule,
          library: library
        )
      } catch {
        exportError = error.localizedDescription
      }
    }
  }
}

private struct CapsuleArtwork: View {
  let songs: [LibrarySong]
  let size: CGFloat
  @Environment(ThemeManager.self) private var themeManager

  @ViewBuilder
  var body: some View {
    if let artworkPath = songs.first?.effectiveArtworkPath {
      AlbumArtworkView(artworkPath: artworkPath, size: size, cornerRadius: size * 0.12)
        .frame(width: size, height: size)
    } else {
      RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
        .fill(themeManager.cardBackgroundColor)
        .frame(width: size, height: size)
        .overlay {
          Image("ampwave.capsule")
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.42, height: size * 0.42)
            .foregroundStyle(themeManager.accentColor)
        }
    }
  }
}

private struct EditCapsuleSheet: View {
  let capsule: AmpwaveCapsule

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @State private var title: String
  @State private var creatorName: String
  @State private var capsuleDescription: String
  @State private var personalMessage: String
  @State private var playExactlyAsCreated: Bool
  @State private var saveError: String?

  init(capsule: AmpwaveCapsule) {
    self.capsule = capsule
    _title = State(initialValue: capsule.title)
    _creatorName = State(initialValue: capsule.creatorName ?? "")
    _capsuleDescription = State(initialValue: capsule.capsuleDescription ?? "")
    _personalMessage = State(initialValue: capsule.personalMessage ?? "")
    _playExactlyAsCreated = State(initialValue: capsule.playExactlyAsCreated)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Capsule") {
          TextField("Title", text: $title)
          TextField("Your Name (Optional)", text: $creatorName)
          TextField("Short Description (Optional)", text: $capsuleDescription, axis: .vertical)
            .lineLimit(2...4)
        }

        Section("Message") {
          TextField("Write something for the listener…", text: $personalMessage, axis: .vertical)
            .lineLimit(4...8)
        }

        Section("Playback") {
          Toggle("Play Exactly as Created", isOn: $playExactlyAsCreated)
        }
      }
      .navigationTitle("Edit Capsule")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(trimmedTitle.isEmpty)
        }
      }
      .alert("Couldn't Save Capsule", isPresented: saveAlertBinding) {
        Button("OK") { saveError = nil }
      } message: {
        Text(saveError ?? "The Capsule could not be saved.")
      }
    }
    .presentationDetents([.large])
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var saveAlertBinding: Binding<Bool> {
    Binding(
      get: { saveError != nil },
      set: { if !$0 { saveError = nil } }
    )
  }

  private func save() {
    capsule.title = trimmedTitle
    capsule.creatorName = optional(creatorName)
    capsule.capsuleDescription = optional(capsuleDescription)
    capsule.personalMessage = optional(personalMessage)
    capsule.playExactlyAsCreated = playExactlyAsCreated
    capsule.lastModifiedDate = .now
    do {
      try modelContext.save()
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func optional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
