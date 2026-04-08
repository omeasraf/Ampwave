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

  init(groupSongsByAlbum: Bool = true, mergeAlbumDuplicates: Bool = true) {
    self.id = UUID()
    self.groupSongsByAlbum = groupSongsByAlbum
    self.mergeAlbumDuplicates = mergeAlbumDuplicates
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
