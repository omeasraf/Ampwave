//
//  ImageCache.swift
//  Ampwave
//
//  Simple in-memory cache for decoded images to improve scroll performance.
//

internal import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
typealias PlatformImage = NSImage
#endif

@MainActor
final class ImageCache {
  static let shared = ImageCache()
  
  private let cache = NSCache<NSString, PlatformImage>()
  
  private init() {
    // Limit cache size to avoid memory pressure
    cache.countLimit = 100
  }
  
  func image(for key: String) -> PlatformImage? {
    cache.object(forKey: key as NSString)
  }
  
  func insert(_ image: PlatformImage, for key: String) {
    cache.setObject(image, forKey: key as NSString)
  }
  
  func remove(for key: String) {
    cache.removeObject(forKey: key as NSString)
  }
  
  func clear() {
    cache.removeAllObjects()
  }
}
