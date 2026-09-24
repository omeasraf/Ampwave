//
//  PathManager.swift
//  Ampwave
//
//  Handles relative to absolute path conversions for persistent storage.
//

import Foundation

public enum PathManager {
  nonisolated private static let documentsPathPrefix = "documents://"

  /// Audio references must not use the legacy artwork/managed-file repair
  /// heuristics in `resolve`. An absent external path stays external.
  nonisolated static func referencedURL(for path: String) -> URL {
    if path.hasPrefix(documentsPathPrefix) {
      return documentsDirectory.appendingPathComponent(
        String(path.dropFirst(documentsPathPrefix.count))
      ).standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    return baseDirectory.appendingPathComponent(path).standardizedFileURL
  }

  nonisolated static func isInside(_ url: URL, directory: URL) -> Bool {
    let components = url.standardizedFileURL.pathComponents
    let root = directory.standardizedFileURL.pathComponents
    return components.count > root.count && components.starts(with: root)
  }

  /// Bookmarks can follow a deleted item into the provider's trash. Such an
  /// item is no longer part of the source library even while its bytes exist.
  nonisolated static func isTrashed(_ url: URL) -> Bool {
    url.standardizedFileURL.pathComponents.contains {
      [".trash", ".trashes", ".recentlydeleted"].contains($0.lowercased())
    }
  }

  nonisolated static func isDefinitelyMissing(_ url: URL) -> Bool {
    do {
      // Enumerated URLs can retain cached resource values after deletion.
      // Ask the filesystem again instead of trusting that snapshot.
      _ = try FileManager.default.attributesOfItem(atPath: url.path)
      return false
    } catch {
      let error = error as NSError
      // Permission, provider-offline and incomplete enumeration errors are
      // not deletion evidence. Keep those records so reconnecting can recover.
      return error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
  }

  nonisolated static var baseDirectory: URL {
    if let sharedURL = sharedContainerURL {
      return sharedURL
    }
    return documentsDirectory
  }

  nonisolated static var documentsDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  nonisolated static var sharedContainerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ome.ampwave")
  }

  /// Converts an absolute path to a relative path starting from the base directory.
  nonisolated static func relativePath(from absolutePath: String) -> String {
    let basePath = baseDirectory.path
    let documentsPath = documentsDirectory.path

    if absolutePath.hasPrefix(basePath + "/") {
      return String(absolutePath.dropFirst(basePath.count + 1))
    }
    if absolutePath.hasPrefix(documentsPath + "/") {
      return documentsPathPrefix + String(absolutePath.dropFirst(documentsPath.count + 1))
    }
    return absolutePath
  }

  /// Converts a relative path back to an absolute URL in the current base directory.
  nonisolated static func absoluteURL(for relativePath: String?) -> URL? {
    guard let relativePath = relativePath, !relativePath.isEmpty else { return nil }

    if relativePath.hasPrefix(documentsPathPrefix) {
      return documentsDirectory.appendingPathComponent(
        String(relativePath.dropFirst(documentsPathPrefix.count))
      ).standardizedFileURL
    }

    // If it's already an absolute path that exists, return it (for transition)
    if relativePath.hasPrefix("/") && FileManager.default.fileExists(atPath: relativePath) {
      return URL(fileURLWithPath: relativePath)
    }

    return baseDirectory.appendingPathComponent(relativePath)
  }

  /// Resolves a path that might be absolute (stale) or relative to the current environment.
  nonisolated static func resolve(_ path: String?) -> URL? {
    guard let path = path, !path.isEmpty else { return nil }

    if path.hasPrefix(documentsPathPrefix) {
      return documentsDirectory.appendingPathComponent(
        String(path.dropFirst(documentsPathPrefix.count))
      ).standardizedFileURL
    }

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
  nonisolated static func createBookmark(for url: URL) -> Data? {
    do {
      #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
      #else
        let options: URL.BookmarkCreationOptions = .minimalBookmark
      #endif
      return try url.bookmarkData(
        options: options,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      print("[DEBUG] PathManager.createBookmark: Failed to create bookmark: \(error)")
      return nil
    }
  }

  /// Resolves a security-scoped bookmark into a URL.
  nonisolated static func resolveBookmark(_ data: Data) -> URL? {
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
