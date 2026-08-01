//
//  AddSongsToPlaylistSheet.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/10/26.
//
import SwiftData
internal import SwiftUI

/// How the picker buckets songs into sections.
enum AddSongsGrouping: String, CaseIterable, Identifiable {
  case album
  case artist
  case title

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .album:  return "Album"
    case .artist: return "Artist"
    case .title:  return "Title"
    }
  }
}

struct AddSongsToPlaylistSheet: View {
  let playlist: Playlist

  @State private var searchText = ""
  @State private var selectedSongs = Set<UUID>()
  @State private var grouping: AddSongsGrouping = .album
  /// songId → searchable lyric text, built once instead of hitting the database
  /// for every song on every keystroke.
  @State private var lyricIndex: [UUID: String] = [:]

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  private var library: SongLibrary { SongLibrary.shared }
  private var playlistManager: PlaylistManager { PlaylistManager.shared }

  // MARK: - Filtering

  private var availableSongs: [LibrarySong] {
    let existingIds = Set(playlist.orderedSongs.map { $0.id })
    return library.songs.filter { !existingIds.contains($0.id) }
  }

  var filteredSongs: [LibrarySong] {
    guard !searchText.isEmpty else { return availableSongs }

    return availableSongs.filter { song in
      if song.title.localizedCaseInsensitiveContains(searchText)
        || song.artist.localizedCaseInsensitiveContains(searchText)
        || (song.album ?? "").localizedCaseInsensitiveContains(searchText)
      {
        return true
      }

      // Lyrics are only worth searching for a real term, and only against the
      // prebuilt index.
      guard searchText.count >= 3 else { return false }
      if song.lyrics?.localizedCaseInsensitiveContains(searchText) == true { return true }
      return lyricIndex[song.id]?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }

  // MARK: - Grouping

  private struct SongSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let songs: [LibrarySong]
  }

  private var sections: [SongSection] {
    let songs = filteredSongs

    switch grouping {
    case .album:
      let buckets = Dictionary(grouping: songs) { song in
        "\(song.album ?? "Unknown Album")\u{1}\(song.albumArtist ?? song.artist)"
      }
      return buckets.map { key, value in
        let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
        return SongSection(
          id: key,
          title: String(parts.first ?? "Unknown Album"),
          subtitle: parts.count > 1 ? String(parts[1]) : nil,
          songs: value.sorted(by: LibrarySong.albumTrackOrder)
        )
      }
      .sorted {
        let artistOrder = ($0.subtitle ?? "").localizedCaseInsensitiveCompare($1.subtitle ?? "")
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }

    case .artist:
      let buckets = Dictionary(grouping: songs) { $0.artist }
      return buckets.map { artist, value in
        SongSection(
          id: artist,
          title: artist,
          subtitle: nil,
          songs: value.sorted {
            let albumOrder = ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "")
            if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
            return LibrarySong.albumTrackOrder($0, $1)
          }
        )
      }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    case .title:
      let buckets = Dictionary(grouping: songs) { song -> String in
        guard let first = song.title.trimmingCharacters(in: .whitespaces).first else { return "#" }
        return first.isLetter ? String(first).uppercased() : "#"
      }
      return buckets.map { letter, value in
        SongSection(
          id: letter,
          title: letter,
          subtitle: nil,
          songs: value.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
          }
        )
      }
      .sorted { $0.title < $1.title }
    }
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Group by", selection: $grouping) {
            ForEach(AddSongsGrouping.allCases) { option in
              Text(option.displayName).tag(option)
            }
          }
          .pickerStyle(.segmented)
        }

        if filteredSongs.isEmpty {
          Section {
            ContentUnavailableView(
              searchText.isEmpty ? "No Songs Available" : "No Results",
              systemImage: searchText.isEmpty ? "music.note" : "magnifyingglass",
              description: Text(
                searchText.isEmpty
                  ? "All songs are already in this playlist"
                  : "No songs match your search"
              )
            )
          }
        } else {
          ForEach(sections) { section in
            Section {
              ForEach(section.songs) { song in
                songRow(song)
              }
            } header: {
              sectionHeader(section)
            }
          }
        }
      }
      .searchable(text: $searchText, prompt: "Search songs, artists, lyrics...")
      .navigationTitle("Add Songs")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add (\(selectedSongs.count))") {
            playlistManager.addSongs(orderedSelection(), to: playlist)
            dismiss()
          }
          .disabled(selectedSongs.isEmpty)
        }
      }
      .task { buildLyricIndex() }
    }
  }

  private func songRow(_ song: LibrarySong) -> some View {
    HStack {
      SongRow(song: song, isCurrent: false)

      Spacer()

      Image(systemName: selectedSongs.contains(song.id) ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(selectedSongs.contains(song.id) ? .pink : .secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if selectedSongs.contains(song.id) {
        selectedSongs.remove(song.id)
      } else {
        selectedSongs.insert(song.id)
      }
    }
  }

  /// Header doubles as a select-all control, so a whole album goes in with one
  /// tap instead of one tap per track.
  private func sectionHeader(_ section: SongSection) -> some View {
    let ids = section.songs.map(\.id)
    let allSelected = ids.allSatisfy { selectedSongs.contains($0) }

    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(section.title)
        if let subtitle = section.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textCase(nil)
        }
      }

      Spacer()

      Button(allSelected ? "Deselect" : "Select All") {
        if allSelected {
          ids.forEach { selectedSongs.remove($0) }
        } else {
          ids.forEach { selectedSongs.insert($0) }
        }
      }
      .font(.caption.weight(.semibold))
      .textCase(nil)
      .buttonStyle(.borderless)
    }
  }

  /// Adds songs in the order they're shown, not in library order, so an album
  /// selected as a block lands in track order.
  private func orderedSelection() -> [LibrarySong] {
    sections.flatMap { $0.songs }.filter { selectedSongs.contains($0.id) }
  }

  private func buildLyricIndex() {
    guard lyricIndex.isEmpty else { return }
    guard let cached = try? modelContext.fetch(FetchDescriptor<SyncedLyric>()) else { return }
    lyricIndex = Dictionary(
      cached.map { ($0.songId, $0.lines.map(\.text).joined(separator: " ")) },
      uniquingKeysWith: { first, _ in first }
    )
  }
}
