//
//  AirPlayButton.swift
//  Ampwave
//

import AVKit
internal import SwiftUI

#if os(iOS)
  struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
      let picker = AVRoutePickerView()
      picker.tintColor = tintColor
      picker.activeTintColor = tintColor
      picker.backgroundColor = .clear
      picker.prioritizesVideoDevices = false
      return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
      uiView.tintColor = tintColor
      uiView.activeTintColor = tintColor
    }
  }
#endif
