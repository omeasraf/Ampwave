//
//  DataExtensions.swift
//  Ampwave
//

import CryptoKit
import Foundation

extension Data {
  func sha256() -> String {
    let hash = SHA256.hash(data: self)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
  }
}
