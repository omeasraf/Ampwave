import Foundation
import Security

struct WebDAVConfiguration: Sendable {
  let baseURL: URL
  let username: String
  let password: String
}

struct WebDAVItem: Identifiable, Hashable, Sendable {
  let url: URL
  let name: String
  let isDirectory: Bool
  let contentLength: Int64?
  let modifiedAt: Date?

  var id: URL { url }

  var isAudioFile: Bool {
    WebDAVClient.supportedAudioExtensions.contains(url.pathExtension.lowercased())
  }
}

enum WebDAVError: LocalizedError {
  case invalidServerURL
  case notConfigured
  case invalidResponse
  case requestFailed(statusCode: Int)
  case authenticationFailed
  case malformedDirectoryResponse
  case downloadFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      return "Enter a valid HTTP or HTTPS WebDAV server URL."
    case .notConfigured:
      return "Configure your WebDAV server in Settings first."
    case .invalidResponse:
      return "The WebDAV server returned an invalid response."
    case .requestFailed(let statusCode):
      return "The WebDAV request failed with status \(statusCode)."
    case .authenticationFailed:
      return "The WebDAV username or password was rejected."
    case .malformedDirectoryResponse:
      return "The server returned a directory listing Ampwave could not read."
    case .downloadFailed(let name):
      return "Could not download \(name)."
    }
  }
}

enum WebDAVSettingsStore {
  private static let serverURLKey = "com.ampwave.webdav.serverURL"
  private static let usernameKey = "com.ampwave.webdav.username"
  private static let keychainService = "com.ome.Ampwave.webdav"
  private static let keychainAccount = "default"

  static var serverURLString: String {
    UserDefaults.standard.string(forKey: serverURLKey) ?? ""
  }

  static var username: String {
    UserDefaults.standard.string(forKey: usernameKey) ?? ""
  }

  static var password: String {
    readPassword()
  }

  static var isConfigured: Bool {
    configuration() != nil
  }

  static func normalizedURL(from rawValue: String) -> URL? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host != nil
    else {
      return nil
    }

    if components.path.isEmpty {
      components.path = "/"
    } else if !components.path.hasSuffix("/") {
      components.path += "/"
    }
    components.query = nil
    components.fragment = nil
    return components.url
  }

  static func configuration() -> WebDAVConfiguration? {
    guard let baseURL = normalizedURL(from: serverURLString) else { return nil }
    return WebDAVConfiguration(
      baseURL: baseURL,
      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
      password: password
    )
  }

  static func save(serverURL: String, username: String, password: String) throws {
    guard let normalizedURL = normalizedURL(from: serverURL) else {
      throw WebDAVError.invalidServerURL
    }

    try savePassword(password)
    UserDefaults.standard.set(normalizedURL.absoluteString, forKey: serverURLKey)
    UserDefaults.standard.set(
      username.trimmingCharacters(in: .whitespacesAndNewlines),
      forKey: usernameKey
    )
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: serverURLKey)
    UserDefaults.standard.removeObject(forKey: usernameKey)
    deletePassword()
  }

  private static func readPassword() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else {
      return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private static func savePassword(_ password: String) throws {
    deletePassword()
    guard !password.isEmpty else { return }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecValueData as String: Data(password.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Could not save the WebDAV password securely."]
      )
    }
  }

  private static func deletePassword() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

final class WebDAVClient {
  static let supportedAudioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff",
    "aif", "wma", "alac", "m4b",
  ]

  private let configuration: WebDAVConfiguration
  private let authenticationDelegate: WebDAVAuthenticationDelegate
  private let session: URLSession

  init(configuration: WebDAVConfiguration) {
    self.configuration = configuration
    let delegate = WebDAVAuthenticationDelegate(
      username: configuration.username,
      password: configuration.password
    )
    self.authenticationDelegate = delegate

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 45
    sessionConfiguration.timeoutIntervalForResource = 60 * 30
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(
      configuration: sessionConfiguration,
      delegate: delegate,
      delegateQueue: nil
    )
  }

  deinit {
    session.invalidateAndCancel()
  }

  func testConnection() async throws {
    _ = try await listDirectory(at: configuration.baseURL)
  }

  func listDirectory(at directoryURL: URL) async throws -> [WebDAVItem] {
    var request = authorizedRequest(url: directoryURL)
    request.httpMethod = "PROPFIND"
    request.setValue("1", forHTTPHeaderField: "Depth")
    request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      """
      <?xml version="1.0" encoding="utf-8" ?>
      <d:propfind xmlns:d="DAV:">
        <d:prop>
          <d:displayname />
          <d:resourcetype />
          <d:getcontentlength />
          <d:getlastmodified />
        </d:prop>
      </d:propfind>
      """.utf8
    )

    let (data, response) = try await session.data(for: request)
    try validate(response)

    let parserDelegate = WebDAVMultiStatusParser(baseURL: configuration.baseURL)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = parserDelegate
    guard parser.parse() else {
      throw parser.parserError ?? WebDAVError.malformedDirectoryResponse
    }

    let currentPath = normalizedPath(directoryURL)
    return parserDelegate.items
      .filter { normalizedPath($0.url) != currentPath }
      .filter { $0.isDirectory || $0.isAudioFile }
      .sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
  }

  func download(_ item: WebDAVItem, to directory: URL) async throws -> URL {
    guard !item.isDirectory else { throw WebDAVError.downloadFailed(item.name) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let (temporaryURL, response) = try await session.download(
      for: authorizedRequest(url: item.url)
    )
    try validate(response)

    let safeName = sanitizedFilename(item.name, fallbackURL: item.url)
    var destinationURL = directory.appendingPathComponent(safeName)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      destinationURL = directory.appendingPathComponent(
        "\(UUID().uuidString)-\(safeName)"
      )
    }

    do {
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
      return destinationURL
    } catch {
      throw WebDAVError.downloadFailed(item.name)
    }
  }

  private func authorizedRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    if !configuration.username.isEmpty {
      let value = Data(
        "\(configuration.username):\(configuration.password)".utf8
      ).base64EncodedString()
      request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func validate(_ response: URLResponse) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WebDAVError.invalidResponse
    }
    switch httpResponse.statusCode {
    case 200...299:
      return
    case 401, 403:
      throw WebDAVError.authenticationFailed
    default:
      throw WebDAVError.requestFailed(statusCode: httpResponse.statusCode)
    }
  }

  private func normalizedPath(_ url: URL) -> String {
    let decoded = url.path.removingPercentEncoding ?? url.path
    if decoded.count > 1, decoded.hasSuffix("/") {
      return String(decoded.dropLast())
    }
    return decoded
  }

  private func sanitizedFilename(_ name: String, fallbackURL: URL) -> String {
    let proposed = name.isEmpty
      ? (fallbackURL.lastPathComponent.removingPercentEncoding
        ?? fallbackURL.lastPathComponent)
      : name
    let invalidCharacters = CharacterSet(charactersIn: "/:\\")
      .union(.controlCharacters)
    let components = proposed.components(separatedBy: invalidCharacters)
    let sanitized = components.filter { !$0.isEmpty }.joined(separator: "_")
    return sanitized.isEmpty ? "WebDAV-\(UUID().uuidString)" : sanitized
  }
}

private final class WebDAVAuthenticationDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let username: String
  private let password: String

  init(username: String, password: String) {
    self.username = username
    self.password = password
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (
      URLSession.AuthChallengeDisposition, URLCredential?
    ) -> Void
  ) {
    let method = challenge.protectionSpace.authenticationMethod
    let supportedMethods = [
      NSURLAuthenticationMethodHTTPBasic,
      NSURLAuthenticationMethodHTTPDigest,
      NSURLAuthenticationMethodDefault,
    ]

    if supportedMethods.contains(method), !username.isEmpty,
      challenge.previousFailureCount == 0
    {
      completionHandler(
        .useCredential,
        URLCredential(user: username, password: password, persistence: .forSession)
      )
    } else if method == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
  private let baseURL: URL
  private(set) var items: [WebDAVItem] = []

  private var currentElement = ""
  private var textBuffer = ""
  private var href = ""
  private var displayName = ""
  private var contentLength: Int64?
  private var modifiedAt: Date?
  private var isDirectory = false

  init(baseURL: URL) {
    self.baseURL = baseURL
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName.lowercased()
    textBuffer = ""
    if currentElement == "response" {
      href = ""
      displayName = ""
      contentLength = nil
      modifiedAt = nil
      isDirectory = false
    } else if currentElement == "collection" {
      isDirectory = true
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    textBuffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let element = elementName.lowercased()
    let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

    switch element {
    case "href":
      href = value
    case "displayname":
      displayName = value
    case "getcontentlength":
      contentLength = Int64(value)
    case "getlastmodified":
      modifiedAt = Self.httpDateFormatter.date(from: value)
    case "response":
      appendCurrentItem()
    default:
      break
    }
    textBuffer = ""
  }

  private func appendCurrentItem() {
    guard !href.isEmpty,
      let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
    else {
      return
    }

    let fallbackName =
      url.lastPathComponent.removingPercentEncoding
      ?? url.lastPathComponent
    let resolvedName = displayName.removingPercentEncoding ?? displayName
    items.append(
      WebDAVItem(
        url: url,
        name: resolvedName.isEmpty ? fallbackName : resolvedName,
        isDirectory: isDirectory,
        contentLength: contentLength,
        modifiedAt: modifiedAt
      )
    )
  }

  private static let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter
  }()
}
