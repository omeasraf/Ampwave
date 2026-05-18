//
//  PathManager.swift
//  Ampwave
//
//  Handles relative to absolute path conversions for persistent storage.
//

import Foundation

public enum PathManager {
  static var baseDirectory: URL {
    if let sharedURL = sharedContainerURL {
      return sharedURL
    }
    return documentsDirectory
  }

  static var documentsDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  static var sharedContainerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ome.ampwave")
  }

  /// Converts an absolute path to a relative path starting from the base directory.
  static func relativePath(from absolutePath: String) -> String {
    let absoluteURL = URL(fileURLWithPath: absolutePath)
    let basePath = baseDirectory.path

    if absolutePath.hasPrefix(basePath) {
      let relative = absolutePath.replacingOccurrences(of: basePath, with: "")
      // Remove leading slash if present
      if relative.hasPrefix("/") {
        return String(relative.dropFirst())
      }
      return relative
    }
    return absolutePath
  }

  /// Converts a relative path back to an absolute URL in the current base directory.
  static func absoluteURL(for relativePath: String?) -> URL? {
    guard let relativePath = relativePath, !relativePath.isEmpty else { return nil }

    // If it's already an absolute path that exists, return it (for transition)
    if relativePath.hasPrefix("/") && FileManager.default.fileExists(atPath: relativePath) {
      return URL(fileURLWithPath: relativePath)
    }

    return baseDirectory.appendingPathComponent(relativePath)
  }

  /// Resolves a path that might be absolute (stale) or relative to the current environment.
  static func resolve(_ path: String?) -> URL? {
    guard let path = path, !path.isEmpty else { return nil }

    // 1. Try as relative path against baseDirectory
    let relativeURL = baseDirectory.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: relativeURL.path) {
      return relativeURL
    }
    
    // 2. Try as relative path against legacy documentsDirectory
    let legacyURL = documentsDirectory.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: legacyURL.path) {
      return legacyURL
    }

    // 3. Try as absolute path (if it happens to be valid in this session)
    if path.hasPrefix("/") {
      let absoluteURL = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: absoluteURL.path) {
        return absoluteURL
      }

      // 4. It was absolute but is now stale. Extract the filename/relative part.
      // Assuming structure is .../Songs/Artist/Album/File.mp3
      // or .../.artwork-cache/Hash.jpg
      if let songsRange = path.range(of: "/Songs/") {
        let relative = String(path[songsRange.lowerBound...]).dropFirst()  // "Songs/..."
        return baseDirectory.appendingPathComponent(String(relative))
      }

      if let artworkRange = path.range(of: "/.artwork-cache/") {
        let relative = String(path[artworkRange.lowerBound...]).dropFirst()  // ".artwork-cache/..."
        return baseDirectory.appendingPathComponent(String(relative))
      }
      
      if let artworkRange = path.range(of: "/Artwork/") {
        let relative = String(path[artworkRange.lowerBound...]).dropFirst()  // "Artwork/..."
        return baseDirectory.appendingPathComponent(String(relative))
      }

      // Fallback: just use the last two components if they might form a relative path
      let components = path.components(separatedBy: "/")
      if components.count >= 2 {
        let lastTwo = components.suffix(2).joined(separator: "/")
        let fallbackURL = baseDirectory.appendingPathComponent(lastTwo)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
          return fallbackURL
        }
      }
    }

    return relativeURL  // Return the relative one against baseDirectory even if it doesn't exist yet
  }

  // MARK: - Security Bookmarks

  /// Creates a security-scoped bookmark for an external URL.
  static func createBookmark(for url: URL) -> Data? {
    do {
      return try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      print("[DEBUG] PathManager.createBookmark: Failed to create bookmark: \(error)")
      return nil
    }
  }

  /// Resolves a security-scoped bookmark into a URL.
  static func resolveBookmark(_ data: Data) -> URL? {
    do {
      var isStale = false
      #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
      #else
        let options: URL.BookmarkResolutionOptions = []
      #endif

      let url = try URL(
        resolvingBookmarkData: data,
        options: options,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )

      if isStale {
        print("[DEBUG] PathManager.resolveBookmark: Bookmark is stale")
        // We could try to recreate it if we had the original URL,
        // but for now we just return the resolved one.
      }

      return url
    } catch {
      print("[DEBUG] PathManager.resolveBookmark: Failed to resolve bookmark: \(error)")
      return nil
    }
  }
}
