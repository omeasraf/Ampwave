//
//  LastFMCredentialStore.swift
//  Ampwave
//
//  Keychain storage for the Last.fm session key.
//
//  The session key doesn't expire and grants scrobbling on the user's behalf,
//  so it belongs in the Keychain rather than UserDefaults. The username sits
//  alongside it — harmless on its own, but keeping them together means signing
//  out can't leave one behind.
//

import Foundation
import Security

enum LastFMCredentialStore {
  private static let service = "com.ome.Ampwave.lastfm"
  private static let account = "session"

  struct Credentials: Codable, Equatable {
    var sessionKey: String
    var username: String
  }

  static func load() -> Credentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
    else { return nil }

    return credentials
  }

  @discardableResult
  static func save(_ credentials: Credentials) -> Bool {
    guard let data = try? JSONEncoder().encode(credentials) else { return false }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    // Update in place if an entry already exists; SecItemAdd would fail with
    // errSecDuplicateItem.
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      // Scrobbles need to go out while the device is locked, so this can't be
      // one of the `WhenUnlocked` tiers.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return true }

    guard updateStatus == errSecItemNotFound else { return false }

    var insert = query
    insert.merge(attributes) { current, _ in current }
    return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
  }

  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
