//
//  ColorExtensions.swift
//  Ampwave
//

internal import SwiftUI

#if os(iOS) || os(watchOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0

        } else {
            return nil
        }

        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }

    func toHex() -> String? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        #if os(macOS)
        let uiColor = NSColor(self)
        guard let rgbColor = uiColor.usingColorSpace(.deviceRGB) else { return nil }
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let uiColor = UIColor(self)
        if !uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            if uiColor.getWhite(&r, alpha: &a) {
                g = r
                b = r
            } else {
                return nil
            }
        }
        #endif

        if a != 1.0 {
            return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        } else {
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }

    func adjusted(by amount: Double) -> Color {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        #if os(macOS)
        let uiColor = NSColor(self)
        guard let rgbColor = uiColor.usingColorSpace(.deviceRGB) else { return self }
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let uiColor = UIColor(self)
        if !uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            if uiColor.getWhite(&r, alpha: &a) {
                g = r
                b = r
            } else {
                return self
            }
        }
        #endif
        
        return Color(
            red: min(max(Double(r) + amount, 0), 1),
            green: min(max(Double(g) + amount, 0), 1),
            blue: min(max(Double(b) + amount, 0), 1),
            opacity: Double(a)
        )
    }

    func lighter(by amount: Double = 0.1) -> Color {
        return adjusted(by: amount)
    }

    func darker(by amount: Double = 0.1) -> Color {
        return adjusted(by: -amount)
    }
}
