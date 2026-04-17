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
  @Query private var preferencesList: [UserPreferences]
  @State private var isPlayerExpanded = false

  var preferences: UserPreferences? {
    preferencesList.first
  }

  var body: some View {
    Group {
      if let preferences = preferences {
        OpenTabView(preferences: preferences, isPlayerExpanded: $isPlayerExpanded)
          .sheet(isPresented: $isPlayerExpanded) {
            OpenPlayerView()
              .themeAware(preferences)
          }
          .themeAware(preferences)
      } else {
        ProgressView()
          .onAppear {
            _ = UserPreferences.getOrCreate(in: modelContext)
          }
      }
    }
    .onAppear {
      print("[DEBUG] ContentView appeared")
    }
  }
}

#Preview {
  ContentView()
}
