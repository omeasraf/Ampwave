//
//  LibraryMaintenanceService.swift
//  Ampwave
//
//  Housekeeping that complements the existing Manage Duplicates and Review
//  Missing Metadata screens: tracks whose *file* has gone missing, and editing
//  tags across many songs at once.
//

import Foundation
import SwiftData

@MainActor
enum LibraryMaintenanceService {

  // MARK: - Missing files

  /// Songs whose audio file is no longer on disk.
  ///
  /// Distinct from "Review Missing Metadata", which is about incomplete tags on
  /// tracks that still play.
  static func findMissingFiles(in songs: [LibrarySong], library: SongLibrary) -> [LibrarySong] {
    songs.filter { !library.fileExists(for: $0) }
  }

  // MARK: - Bulk tag editing

  /// Fields a bulk edit can set. `nil` means "leave alone".
  struct TagEdit {
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var year: Int?

    var isEmpty: Bool {
      artist == nil && albumArtist == nil && album == nil && genre == nil && year == nil
    }
  }

  /// Applies `edit` to every song in `songs`, marking the touched fields as
  /// user-edited so later metadata fetches don't overwrite them.
  static func applyTags(
    _ edit: TagEdit,
    to songs: [LibrarySong],
    modelContext: ModelContext
  ) {
    guard !edit.isEmpty else { return }

    for song in songs {
      if let artist = edit.artist, !artist.isEmpty {
        song.artist = artist
        song.artists = [artist]
        markEdited("artist", on: song)
      }
      if let albumArtist = edit.albumArtist, !albumArtist.isEmpty {
        song.albumArtist = albumArtist
        markEdited("albumArtist", on: song)
      }
      if let album = edit.album, !album.isEmpty {
        song.album = album
        markEdited("album", on: song)
      }
      if let genre = edit.genre, !genre.isEmpty {
        song.genre = genre
        markEdited("genre", on: song)
      }
      if let year = edit.year {
        song.year = year
        markEdited("year", on: song)
      }
    }

    try? modelContext.save()
  }

  private static func markEdited(_ field: String, on song: LibrarySong) {
    if !song.userEditedFields.contains(field) {
      song.userEditedFields.append(field)
    }
  }

  // MARK: - Duplicate merge support

  /// Folds `duplicate`'s listening history into `keeper` and repoints playlist
  /// entries, so removing the duplicate doesn't cost play counts or silently
  /// shrink playlists.
  ///
  /// Call this immediately before deleting `duplicate`.
  static func transferState(
    from duplicate: LibrarySong,
    to keeper: LibrarySong,
    tracker: ListeningHistoryTracker,
    playlists: PlaylistManager,
    modelContext: ModelContext
  ) {
    guard duplicate.id != keeper.id else { return }

    let stats = tracker.statisticsBySongId()
    if let dupStats = stats[duplicate.id] {
      if let keeperStats = stats[keeper.id] {
        keeperStats.playCount += dupStats.playCount
        keeperStats.skipCount += dupStats.skipCount
        keeperStats.totalPlayTime += dupStats.totalPlayTime
        if let dupLast = dupStats.lastPlayedAt {
          keeperStats.lastPlayedAt = max(keeperStats.lastPlayedAt ?? dupLast, dupLast)
        }
        keeperStats.isLiked = keeperStats.isLiked || dupStats.isLiked
        if keeperStats.userRating == nil { keeperStats.userRating = dupStats.userRating }
        modelContext.delete(dupStats)
      } else {
        // Nothing to merge into — just move the record across.
        dupStats.songId = keeper.id
      }
      tracker.invalidateStatisticsIndex()
    }

    playlists.replaceSong(duplicate, with: keeper)
  }
}
