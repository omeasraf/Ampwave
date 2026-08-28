import Foundation

/// Lightweight, shareable diagnostics for TestFlight playback issues.
///
/// Files live in Documents/logs so they are visible in Files under Ampwave.
/// A separate UTF-8 file is used for each app launch and files older than seven
/// days are removed automatically.
final class DiagnosticLog: @unchecked Sendable {
  static let shared = DiagnosticLog()

  private let lock = NSLock()
  private let fileManager = FileManager.default
  private let directoryURL: URL
  private let sessionFileURL: URL
  private let timestampFormatter: ISO8601DateFormatter

  private init() {
    directoryURL = PathManager.documentsDirectory.appendingPathComponent("logs", isDirectory: true)

    timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let sessionFormatter = DateFormatter()
    sessionFormatter.locale = Locale(identifier: "en_US_POSIX")
    sessionFormatter.calendar = Calendar(identifier: .gregorian)
    sessionFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let sessionID = UUID().uuidString.prefix(8)
    sessionFileURL = directoryURL.appendingPathComponent(
      "ampwave-session-\(sessionFormatter.string(from: Date()))-\(sessionID).log"
    )

    try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    #if os(iOS)
      try? fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directoryURL.path
      )
    #endif
    removeExpiredFiles()
    log("app", "Diagnostic session started file=\(sessionFileURL.lastPathComponent)")
  }

  func log(_ category: String, _ message: @autoclosure () -> String) {
    lock.lock()
    defer { lock.unlock() }

    let now = Date()
    let line = "\(timestampFormatter.string(from: now)) [\(category.uppercased())] \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    // Mirror file diagnostics to the device/Xcode console so a connected
    // development run and a shared session file contain the same evidence.
    Swift.print(line, terminator: "")

    do {
      if !fileManager.fileExists(atPath: sessionFileURL.path) {
        try data.write(to: sessionFileURL, options: .atomic)
        #if os(iOS)
          try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: sessionFileURL.path
          )
        #endif
      } else {
        let handle = try FileHandle(forWritingTo: sessionFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
      }
    } catch {
      // Diagnostics must never interfere with playback.
    }
  }

  private func removeExpiredFiles() {
    guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
      let files = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    for file in files where file.pathExtension == "log" {
      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
      if let modified = values?.contentModificationDate, modified < cutoff {
        try? fileManager.removeItem(at: file)
      }
    }
  }
}
