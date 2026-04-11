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

      let inputImage = CIImage(cgImage: cgImage)
      let extent = inputImage.extent

      // Use Core Image area average with quantization
      let filter = CIFilter(
        name: "CIAreaAverage",
        parameters: [
          kCIInputImageKey: inputImage,
          kCIInputExtentKey: CIVector(cgRect: extent),
        ]
      )

      guard let outputImage = filter?.outputImage else { return nil }

      var bitmap = [UInt8](repeating: 0, count: 4)
      let context = CIContext(options: [.workingColorSpace: NSNull()])

      context.render(
        outputImage,
        toBitmap: &bitmap,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: nil
      )

      return Color(
        red: Double(bitmap[0]) / 255.0,
        green: Double(bitmap[1]) / 255.0,
        blue: Double(bitmap[2]) / 255.0
      )
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
          size: size,
          flipped: false,
          drawingHandler: { rect in
            self.draw(in: rect)
            return true
          }
        )
      else { return nil }

      guard let resizedTiff = resizedImage.tiffRepresentation,
        let resizedBitmap = NSBitmapImageRep(data: resizedTiff)
      else { return nil }

      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard let color = resizedBitmap.colorAt(x: 0, y: 0) else {
        return nil
      }
      color.getRed(&r, green: &g, blue: &b, alpha: &a)

      return Color(red: r, green: g, blue: b)
    }
  }
#endif
