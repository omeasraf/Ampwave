import AVFoundation
import Foundation

/// Controls which source layouts Ampwave permits the system to spatialize.
/// The listener's Control Center choice and the current output route still win.
enum SpatialAudioMode: String, CaseIterable, Identifiable {
  case off
  case multichannel
  case allSupported

  static let defaultsKey = "com.ampwave.spatialAudioMode"

  static var current: Self {
    guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
      let saved = Self(rawValue: rawValue)
    else { return .multichannel }
    return saved
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "Off"
    case .multichannel: "Multichannel"
    case .allSupported: "Multichannel + Spatialize Stereo"
    }
  }

  var explanation: String {
    switch self {
    case .off:
      "Play the source without system spatialization. Surround channels remain available to compatible outputs."
    case .multichannel:
      "Let iOS spatialize surround recordings on supported headphones and speakers."
    case .allSupported:
      "Also allow iOS to spatialize ordinary mono and stereo recordings. This does not turn them into Dolby Atmos mixes."
    }
  }

  var allowedFormats: AVAudioSpatializationFormats {
    switch self {
    case .off: []
    case .multichannel: .multichannel
    case .allSupported: .monoStereoAndMultichannel
    }
  }

  func apply(to item: AVPlayerItem) {
    item.allowedAudioSpatializationFormats = allowedFormats
  }
}
