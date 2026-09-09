/// Keeps development diagnostics available in Xcode without emitting hundreds
/// of ad-hoc console messages from production builds. Persistent session logs
/// continue to be written through `DiagnosticLog` in every configuration.
@inline(__always)
nonisolated func print(
  _ items: Any...,
  separator: String = " ",
  terminator: String = "\n"
) {
  #if DEBUG
    Swift.print(
      items.map { String(describing: $0) }.joined(separator: separator),
      terminator: terminator
    )
  #endif
}
