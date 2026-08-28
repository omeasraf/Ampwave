//
//  ExpandableDescriptionView.swift
//  Ampwave
//
//  Shared presentation for album descriptions, artist biographies, and other
//  longer editorial text.
//

internal import SwiftUI

struct ExpandableDescriptionView: View {
  let text: String
  var collapsedLineLimit: Int = 4

  @State private var isExpanded = false
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .lineLimit(isExpanded ? nil : collapsedLineLimit)

      Button(isExpanded ? "Show Less" : "Read More") {
        withAnimation(.snappy(duration: 0.25)) {
          isExpanded.toggle()
        }
      }
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(themeManager.accentColor)
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded ? "Collapses the description" : "Expands the full description")
    }
    .onChange(of: text) {
      isExpanded = false
    }
  }
}

