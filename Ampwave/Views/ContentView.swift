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
  @State private var isPlayerExpanded = false

  var body: some View {
    OpenTabView(isPlayerExpanded: $isPlayerExpanded)
      .sheet(isPresented: $isPlayerExpanded) {
        OpenPlayerView()
      }
      .onAppear {
        print("[DEBUG] ContentView appeared")
      }
  }
}

#Preview {
  ContentView()
}
