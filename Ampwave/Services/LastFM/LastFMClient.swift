//
//  LastFMClient.swift
//  Ampwave
//
//  Thin wrapper over the Last.fm 2.0 API.
//
//  Auth follows the desktop-app flow Last.fm documents for clients that can't
//  keep a secret in a browser redirect:
//    1. auth.getToken                     → a request token
//    2. open last.fm/api/auth?token=…     → user approves in Safari
//    3. auth.getSession                   → a session key that does not expire
//  The session key is all we persist; the request token is single-use.
//

import CryptoKit
import Foundation

enum LastFMError: LocalizedError {
  case notConfigured
  case notAuthenticated
  case api(code: Int, message: String)
  case transport(Error)
  case malformedResponse

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Last.fm isn't configured in this build."
    case .notAuthenticated:
      return "Not signed in to Last.fm."
    case .api(let code, let message):
      // Code 14/15 are the "user hasn't approved the token yet" cases, which
      // the sign-in flow surfaces as a retry rather than a hard failure.
      return "Last.fm error \(code): \(message)"
    case .transport(let error):
      return error.localizedDescription
    case .malformedResponse:
      return "Unexpected response from Last.fm."
    }
  }

  /// True when the user simply hasn't finished approving in the browser.
  var isPendingAuthorization: Bool {
    if case .api(let code, _) = self { return code == 14 || code == 15 }
    return false
  }
}

struct LastFMProfile: Codable, Equatable {
  var username: String
  var realName: String?
  var playCount: Int?
  var imageURL: URL?
  var profileURL: URL?
}

/// One track play, ready to send.
struct LastFMScrobbleItem: Codable, Equatable {
  var artist: String
  var track: String
  var album: String?
  var albumArtist: String?
  var duration: Int?
  var trackNumber: Int?
  /// Unix time the track *started*, which is what Last.fm scrobbles against.
  var timestamp: Int
}

actor LastFMClient {
  static let shared = LastFMClient()

  private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  var isConfigured: Bool { LastFMSecrets.isConfigured }

  /// The page the user approves the request token on.
  nonisolated func authorizationURL(token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
    components?.queryItems = [
      URLQueryItem(name: "api_key", value: LastFMSecrets.apiKey),
      URLQueryItem(name: "token", value: token),
    ]
    return components?.url
  }

  // MARK: - Auth

  func requestToken() async throws -> String {
    let json = try await send(method: "auth.getToken", params: [:], signed: true, httpMethod: "GET")
    guard let token = json["token"] as? String else { throw LastFMError.malformedResponse }
    return token
  }

  /// Exchanges an approved request token for a durable session key.
  func session(token: String) async throws -> (key: String, username: String) {
    let json = try await send(
      method: "auth.getSession",
      params: ["token": token],
      signed: true,
      httpMethod: "GET"
    )
    guard let session = json["session"] as? [String: Any],
      let key = session["key"] as? String,
      let name = session["name"] as? String
    else { throw LastFMError.malformedResponse }
    return (key, name)
  }

  // MARK: - Profile

  func profile(username: String) async throws -> LastFMProfile {
    let json = try await send(
      method: "user.getInfo",
      params: ["user": username],
      signed: false,
      httpMethod: "GET"
    )
    guard let user = json["user"] as? [String: Any] else { throw LastFMError.malformedResponse }

    // Images come back as an array of {#text, size}; take the largest non-empty.
    let imageURL = (user["image"] as? [[String: Any]])?
      .compactMap { $0["#text"] as? String }
      .last(where: { !$0.isEmpty })
      .flatMap(URL.init(string:))

    return LastFMProfile(
      username: user["name"] as? String ?? username,
      realName: (user["realname"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      playCount: (user["playcount"] as? String).flatMap(Int.init),
      imageURL: imageURL,
      profileURL: (user["url"] as? String).flatMap(URL.init(string:))
    )
  }

  // MARK: - Loved tracks

  /// Marks a track loved (or removes it) on the user's Last.fm profile.
  func setLoved(_ loved: Bool, artist: String, track: String, sessionKey: String) async throws {
    _ = try await send(
      method: loved ? "track.love" : "track.unlove",
      params: ["artist": artist, "track": track, "sk": sessionKey],
      signed: true,
      httpMethod: "POST"
    )
  }

  // MARK: - Scrobbling

  func updateNowPlaying(_ item: LastFMScrobbleItem, sessionKey: String) async throws {
    var params: [String: String] = [
      "artist": item.artist,
      "track": item.track,
      "sk": sessionKey,
    ]
    if let album = item.album { params["album"] = album }
    if let albumArtist = item.albumArtist { params["albumArtist"] = albumArtist }
    if let duration = item.duration { params["duration"] = String(duration) }
    if let trackNumber = item.trackNumber { params["trackNumber"] = String(trackNumber) }

    _ = try await send(
      method: "track.updateNowPlaying", params: params, signed: true, httpMethod: "POST")
  }

  /// Submits up to 50 plays in one request, which is the documented batch cap.
  /// Returns the items Last.fm accepted so the caller can drop them from its
  /// queue while keeping anything that failed.
  @discardableResult
  func scrobble(_ items: [LastFMScrobbleItem], sessionKey: String) async throws
    -> [LastFMScrobbleItem]
  {
    guard !items.isEmpty else { return [] }
    let batch = Array(items.prefix(50))

    var params: [String: String] = ["sk": sessionKey]
    for (index, item) in batch.enumerated() {
      params["artist[\(index)]"] = item.artist
      params["track[\(index)]"] = item.track
      params["timestamp[\(index)]"] = String(item.timestamp)
      if let album = item.album { params["album[\(index)]"] = album }
      if let albumArtist = item.albumArtist { params["albumArtist[\(index)]"] = albumArtist }
      if let duration = item.duration { params["duration[\(index)]"] = String(duration) }
      if let trackNumber = item.trackNumber { params["trackNumber[\(index)]"] = String(trackNumber) }
    }

    _ = try await send(method: "track.scrobble", params: params, signed: true, httpMethod: "POST")
    return batch
  }

  // MARK: - Transport

  private func send(
    method: String,
    params: [String: String],
    signed: Bool,
    httpMethod: String
  ) async throws -> [String: Any] {
    guard LastFMSecrets.isConfigured else { throw LastFMError.notConfigured }

    var allParams = params
    allParams["method"] = method
    allParams["api_key"] = LastFMSecrets.apiKey
    if signed {
      allParams["api_sig"] = Self.signature(for: allParams)
    }
    // Added after signing on purpose — `format` is excluded from the signature.
    allParams["format"] = "json"

    var request: URLRequest
    if httpMethod == "POST" {
      request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue(
        "application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.formEncoded(allParams).data(using: .utf8)
    } else {
      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
      components.percentEncodedQuery = Self.formEncoded(allParams)
      request = URLRequest(url: components.url!)
      request.httpMethod = "GET"
    }

    let data: Data
    do {
      (data, _) = try await session.data(for: request)
    } catch {
      throw LastFMError.transport(error)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LastFMError.malformedResponse
    }

    // Last.fm reports failures in a 200 body, so the status code isn't enough.
    if let code = json["error"] as? Int {
      throw LastFMError.api(code: code, message: json["message"] as? String ?? "Unknown error")
    }

    return json
  }

  // MARK: - Signing

  /// Last.fm's `api_sig`: every parameter except `format` and `callback`,
  /// sorted by name, concatenated as name+value, then the shared secret,
  /// hashed with MD5.
  static func signature(for params: [String: String]) -> String {
    let joined =
      params
      .filter { $0.key != "format" && $0.key != "callback" && $0.key != "api_sig" }
      .sorted { $0.key < $1.key }
      .map { $0.key + $0.value }
      .joined()

    let digest = Insecure.MD5.hash(data: Data((joined + LastFMSecrets.sharedSecret).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func formEncoded(_ params: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return
      params
      .map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
      }
      .joined(separator: "&")
  }
}
