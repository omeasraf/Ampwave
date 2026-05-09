//
//  IndexingStatusView.swift
//  Ampwave
//
//  Shows indexing status for library scanning.
//

import SwiftData
internal import SwiftUI

struct IndexingStatusView: View {
  private var library: SongLibrary { SongLibrary.shared }
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    Group {
      switch library.indexingStatus {
      case .idle, .complete:
        EmptyView()
      case .indexing(let message):
        HStack(spacing: 10) {
          ProgressView()
            .scaleEffect(0.8)
          Text(message)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(themeManager.accentColor)
      case .fetchingMetadata(let current, let total):
        HStack(spacing: 10) {
          ProgressView()
            .scaleEffect(0.8)
          if total > 1 {
            Text("Fetching metadata (\(current + 1)/\(total))…")
              .font(.system(size: 14))
              .foregroundStyle(.secondary)
          } else {
            Text("Fetching metadata…")
              .font(.system(size: 14))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(themeManager.accentColor)

      }
    }
    .animation(.easeInOut(duration: 0.2), value: library.indexingStatus)
  }
}

#Preview("Indexing") {
  VStack {
    IndexingStatusView()
    Spacer()
  }
}
