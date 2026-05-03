//
//  ImageExtension.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

import CoreImage
import CoreGraphics
internal import SwiftUI

#if os(iOS)
  import UIKit
  typealias PlatformImage = UIImage
#else
  import AppKit
  typealias PlatformImage = NSImage
#endif

#if os(iOS)
  extension Color {
    init(average color: UIColor) {
      let ciColor = CIColor(color: color)
      self = Color(
        red: ciColor.red,
        green: ciColor.green,
        blue: ciColor.blue
      )
    }
  }

  extension UIImage {
    func dominantColor() -> Color? {
      guard let cgImage = self.cgImage else { return nil }
      return DominantColorSampler.dominantColor(from: cgImage)
    }
  }

#else
  extension NSImage {
    func dominantColor() -> Color? {
      guard let tiff = self.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let cgImage = bitmap.cgImage
      else { return nil }

      return DominantColorSampler.dominantColor(from: cgImage)
    }
  }
#endif

private enum DominantColorSampler {
  static func dominantColor(from cgImage: CGImage) -> Color? {
    let maxDimension = 56
    let width = max(1, min(maxDimension, cgImage.width))
    let height = max(1, min(maxDimension, cgImage.height))
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.interpolationQuality = .low
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var buckets: [Int: Bucket] = [:]

    for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      let alpha = Double(pixels[index + 3]) / 255.0
      guard alpha > 0.55 else { continue }

      let red = Double(pixels[index]) / 255.0
      let green = Double(pixels[index + 1]) / 255.0
      let blue = Double(pixels[index + 2]) / 255.0

      let brightness = (red * 0.299) + (green * 0.587) + (blue * 0.114)
      let saturation = max(red, green, blue) - min(red, green, blue)

      guard brightness > 0.16, brightness < 0.92 else { continue }
      guard saturation > 0.08 else { continue }

      let quantizedR = Int(red * 7)
      let quantizedG = Int(green * 7)
      let quantizedB = Int(blue * 7)
      let bucketKey = (quantizedR << 6) | (quantizedG << 3) | quantizedB

      let weightedBrightness = 1.0 - abs(brightness - 0.56)
      let weight = max(0.2, saturation * 1.6 + weightedBrightness)

      buckets[bucketKey, default: .zero].accumulate(
        red: red,
        green: green,
        blue: blue,
        weight: weight
      )
    }

    guard let best = buckets.values.max(by: { $0.weightedCount < $1.weightedCount }),
      best.weightedCount > 0
    else {
      return nil
    }

    let averaged = best.average
    return Color(red: averaged.red, green: averaged.green, blue: averaged.blue)
  }

  private struct Bucket {
    var redTotal: Double = 0
    var greenTotal: Double = 0
    var blueTotal: Double = 0
    var weightedCount: Double = 0

    static let zero = Bucket()

    mutating func accumulate(red: Double, green: Double, blue: Double, weight: Double) {
      redTotal += red * weight
      greenTotal += green * weight
      blueTotal += blue * weight
      weightedCount += weight
    }

    var average: (red: Double, green: Double, blue: Double) {
      guard weightedCount > 0 else { return (0.5, 0.5, 0.5) }
      return (
        redTotal / weightedCount,
        greenTotal / weightedCount,
        blueTotal / weightedCount
      )
    }
  }
}
