//
//  PathManager.swift
//  Ampwave
//
//  Handles relative to absolute path conversions for persistent storage.
//

import Foundation

public enum PathManager {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// Converts an absolute path to a relative path starting from the documents directory.
    static func relativePath(from absolutePath: String) -> String {
        let absoluteURL = URL(fileURLWithPath: absolutePath)
        let docsPath = documentsDirectory.path
        
        if absolutePath.hasPrefix(docsPath) {
            let relative = absolutePath.replacingOccurrences(of: docsPath, with: "")
            // Remove leading slash if present
            if relative.hasPrefix("/") {
                return String(relative.dropFirst())
            }
            return relative
        }
        return absolutePath
    }
    
    /// Converts a relative path back to an absolute URL in the current documents directory.
    static func absoluteURL(for relativePath: String?) -> URL? {
        guard let relativePath = relativePath, !relativePath.isEmpty else { return nil }
        
        // If it's already an absolute path that exists, return it (for transition)
        if relativePath.hasPrefix("/") && FileManager.default.fileExists(atPath: relativePath) {
            return URL(fileURLWithPath: relativePath)
        }
        
        return documentsDirectory.appendingPathComponent(relativePath)
    }
    
    /// Resolves a path that might be absolute (stale) or relative to the current environment.
    static func resolve(_ path: String?) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }
        
        // 1. Try as relative path
        let relativeURL = documentsDirectory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: relativeURL.path) {
            return relativeURL
        }
        
        // 2. Try as absolute path (if it happens to be valid in this session)
        if path.hasPrefix("/") {
            let absoluteURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: absoluteURL.path) {
                return absoluteURL
            }
            
            // 3. It was absolute but is now stale. Extract the filename/relative part.
            // Assuming structure is .../Documents/Songs/Artist/Album/File.mp3 
            // or .../Documents/.artwork-cache/Hash.jpg
            if let songsRange = path.range(of: "/Songs/") {
                let relative = String(path[songsRange.lowerBound...]).dropFirst() // "Songs/..."
                return documentsDirectory.appendingPathComponent(String(relative))
            }
            
            if let artworkRange = path.range(of: "/.artwork-cache/") {
                let relative = String(path[artworkRange.lowerBound...]).dropFirst() // ".artwork-cache/..."
                return documentsDirectory.appendingPathComponent(String(relative))
            }
            
            // Fallback: just use the last two components if they might form a relative path
            let components = path.components(separatedBy: "/")
            if components.count >= 2 {
                let lastTwo = components.suffix(2).joined(separator: "/")
                let fallbackURL = documentsDirectory.appendingPathComponent(lastTwo)
                if FileManager.default.fileExists(atPath: fallbackURL.path) {
                    return fallbackURL
                }
            }
        }
        
        return relativeURL // Return the relative one even if it doesn't exist yet (for writing)
    }
}
