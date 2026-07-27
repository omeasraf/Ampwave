//
//  ContentView.swift
//  Ampwave
//
//  Main content view with mini player and full-screen player presentation.
//

import SwiftData
internal import SwiftUI

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(ThemeManager.self) private var themeManager
  @State private var isPlayerExpanded = false

  var body: some View {
    ZStack {
      themeManager.backgroundColor.ignoresSafeArea()

      #if os(iOS)
        OpenTabView(isPlayerExpanded: $isPlayerExpanded)
        .fullScreenCover(isPresented: $isPlayerExpanded) {
          OpenPlayerView()
        }
      #else
        OpenTabView(isPlayerExpanded: $isPlayerExpanded)
          .sheet(isPresented: $isPlayerExpanded) {
            OpenPlayerView()
          }
      #endif
    }
    .onAppear {
      ThemeManager.shared.ampwaveColorScheme = colorScheme
      print("[DEBUG] ContentView appeared")
    }
    .onChange(of: colorScheme) { _, newValue in
      ThemeManager.shared.ampwaveColorScheme = newValue
    }
  }
}

#Preview {
  ContentView()
}
