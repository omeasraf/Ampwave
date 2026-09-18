//
//  ImageCache.swift
//  Ampwave
//
//  Simple in-memory cache for decoded images to improve scroll performance.
//

internal import SwiftUI
import ImageIO

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

@MainActor
final class ImageCache {
  static let shared = ImageCache()

  private let cache = NSCache<NSString, PlatformImage>()
  private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

  private init() {
    // Bound both object count and decoded pixel memory. A count limit alone
    // still permits a small number of very large album images to consume
    // hundreds of megabytes.
    cache.countLimit = 100
    cache.totalCostLimit = 64 * 1_024 * 1_024
  }

  func image(for key: String) -> PlatformImage? {
    cache.object(forKey: key as NSString)
  }

  func insert(_ image: PlatformImage, for key: String) {
    #if os(iOS)
      let pixelWidth = Int(image.size.width * image.scale)
      let pixelHeight = Int(image.size.height * image.scale)
    #else
      let pixelWidth = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
      let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
    #endif
    cache.setObject(
      image,
      forKey: key as NSString,
      cost: max(1, pixelWidth * pixelHeight * 4)
    )
  }

  /// Returns a size-appropriate decoded image and coalesces simultaneous row
  /// requests for the same artwork. Decoding the original image for a 50-point
  /// list thumbnail wastes memory and was a major source of scroll hitching.
  func thumbnail(for path: String, url: URL, maxPixelSize: Int) async -> PlatformImage? {
    let dimension = max(1, maxPixelSize)
    let key = "\(path)#thumbnail-\(dimension)"

    if let cached = image(for: key) { return cached }
    if let existing = inFlight[key] { return await existing.value }

    let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
      let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
        return nil
      }
      let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: dimension,
      ] as CFDictionary
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
      else { return nil }

      #if os(iOS)
        return UIImage(cgImage: thumbnail)
      #else
        return NSImage(cgImage: thumbnail, size: .zero)
      #endif
    }

    inFlight[key] = task
    let loaded = await task.value
    inFlight[key] = nil
    if let loaded { insert(loaded, for: key) }
    return loaded
  }

  func remove(for key: String) {
    cache.removeObject(forKey: key as NSString)
  }

  func clear() {
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll()
    cache.removeAllObjects()
  }
}
