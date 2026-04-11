//
//  AppSettings.swift
//  Ampwave
//
//  App settings model for library organization preferences.
//

import Foundation
import SwiftData

@Model
final class AppSettings: Identifiable {
  @Attribute(.unique) var id: UUID
  /// Whether to organize songs by album in folder structure
  var groupSongsByAlbum: Bool = true
  /// Whether to automatically merge duplicate albums with same name and artist
  var mergeAlbumDuplicates: Bool = true
  /// Whether to automatically fetch lyrics from online sources
  var autoFetchLyrics: Bool = false
  
  /// Sorting preferences for library tabs
  var songSortOrderRaw: String = LibrarySortOrder.titleAscending.rawValue
  var albumSortOrderRaw: String = LibrarySortOrder.titleAscending.rawValue
  var artistSortOrderRaw: String = LibrarySortOrder.titleAscending.rawValue
  var playlistSortOrderRaw: String = LibrarySortOrder.dateAddedDescending.rawValue

  init(
    groupSongsByAlbum: Bool = true, 
    mergeAlbumDuplicates: Bool = true, 
    autoFetchLyrics: Bool = false,
    songSortOrder: LibrarySortOrder = .titleAscending,
    albumSortOrder: LibrarySortOrder = .titleAscending,
    artistSortOrder: LibrarySortOrder = .titleAscending,
    playlistSortOrder: LibrarySortOrder = .dateAddedDescending
  ) {
    self.id = UUID()
    self.groupSongsByAlbum = groupSongsByAlbum
    self.mergeAlbumDuplicates = mergeAlbumDuplicates
    self.autoFetchLyrics = autoFetchLyrics
    self.songSortOrderRaw = songSortOrder.rawValue
    self.albumSortOrderRaw = albumSortOrder.rawValue
    self.artistSortOrderRaw = artistSortOrder.rawValue
    self.playlistSortOrderRaw = playlistSortOrder.rawValue
  }
  
  var songSortOrder: LibrarySortOrder {
    get { LibrarySortOrder(rawValue: songSortOrderRaw) ?? .titleAscending }
    set { songSortOrderRaw = newValue.rawValue }
  }
  
  var albumSortOrder: LibrarySortOrder {
    get { LibrarySortOrder(rawValue: albumSortOrderRaw) ?? .titleAscending }
    set { albumSortOrderRaw = newValue.rawValue }
  }
  
  var artistSortOrder: LibrarySortOrder {
    get { LibrarySortOrder(rawValue: artistSortOrderRaw) ?? .titleAscending }
    set { artistSortOrderRaw = newValue.rawValue }
  }
  
  var playlistSortOrder: LibrarySortOrder {
    get { LibrarySortOrder(rawValue: playlistSortOrderRaw) ?? .dateAddedDescending }
    set { playlistSortOrderRaw = newValue.rawValue }
  }

  /// Gets or creates the singleton app settings instance
  static func getOrCreate(in modelContext: ModelContext) -> AppSettings {
    do {
      var descriptor = FetchDescriptor<AppSettings>()
      descriptor.fetchLimit = 1
      if let existing = try modelContext.fetch(descriptor).first {
        return existing
      }
    } catch {
      // Continue to create new
    }

    let newSettings = AppSettings()
    modelContext.insert(newSettings)
    try? modelContext.save()
    return newSettings
  }
}
