//
//  ImageExtension.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/3/26.
//

import CoreImage
internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

#if os(iOS)
  extension Color {
    init(average color: UIColor) {
      let ciColor = CIColor(color: color)
      self = Color(red: ciColor.red, green: ciColor.green, blue: ciColor.blue)
    }
  }

  extension UIImage {
    func dominantColor() -> Color? {
      guard let cgImage = self.cgImage else { return nil }

      // Resize image to 1x1 to sample average color
      let size = CGSize(width: 1, height: 1)
      let rect = CGRect(origin: .zero, size: size)

      UIGraphicsBeginImageContextWithOptions(size, true, 0)
      defer { UIGraphicsEndImageContext() }

      guard let context = UIGraphicsGetCurrentContext() else { return nil }

      // Draw the image scaled down to 1x1
      self.draw(in: rect)

      guard let imageData = UIGraphicsGetImageFromCurrentImageContext()?.cgImage else { return nil }

      // Get pixel data
      guard let pixelBuffer = CFDataGetBytePtr(imageData.dataProvider!.data) else { return nil }

      let r = CGFloat(pixelBuffer[0]) / 255.0
      let g = CGFloat(pixelBuffer[1]) / 255.0
      let b = CGFloat(pixelBuffer[2]) / 255.0

      return Color(red: r, green: g, blue: b)
    }
  }
#else
  extension NSImage {
    func dominantColor() -> Color? {
      guard let tiff = self.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let cgImage = bitmap.cgImage
      else { return nil }

      // Resize to 1x1 for average color sampling
      let size = NSSize(width: 1, height: 1)
      guard
        let resizedImage = NSImage(
          size: size, flipped: false,
          drawingHandler: { rect in
            self.draw(in: rect)
            return true
          })
      else { return nil }

      guard let resizedTiff = resizedImage.tiffRepresentation,
        let resizedBitmap = NSBitmapImageRep(data: resizedTiff)
      else { return nil }

      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard let color = resizedBitmap.colorAt(x: 0, y: 0) else { return nil }
      color.getRed(&r, green: &g, blue: &b, alpha: &a)

      return Color(red: r, green: g, blue: b)
    }
  }
#endif
