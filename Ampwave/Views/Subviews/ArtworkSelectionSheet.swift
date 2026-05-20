//
//  ArtworkSelectionSheet.swift
//  Ampwave
//
//  Sheet for selecting artwork from online sources.
//

internal import SwiftUI

struct ArtworkSelectionSheet: View {
  let title: String
  let artist: String
  @Binding var isPresented: Bool
  var onSelect: (URL) -> Void

  @State private var artworkURLs: [URL] = []
  @State private var isLoading = true
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationStack {
      ScrollView {
        if isLoading {
          VStack {
            Spacer(minLength: 50)
            ProgressView("Searching for artwork...")
          }
          .frame(maxWidth: .infinity)
        } else if artworkURLs.isEmpty {
          VStack(spacing: 20) {
            Spacer(minLength: 50)
            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 60))
              .foregroundStyle(.secondary)
            Text("No artwork found")
              .font(.headline)
            Text("Try refining the title or artist.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
            ForEach(artworkURLs, id: \.self) { url in
              ArtworkOptionView(url: url) {
                onSelect(url)
                isPresented = false
              }
            }
          }
          .padding()
        }
      }
      .background(themeManager.backgroundColor)
      .navigationTitle("Select Artwork")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isPresented = false
          }
        }
      }
      .onAppear {
        searchArtwork()
      }
    }
  }

  private func searchArtwork() {
    isLoading = true
    Task {
      let urls = await MetadataService.shared.searchArtworkOptions(title: title, artist: artist)
      await MainActor.run {
        self.artworkURLs = urls
        self.isLoading = false
      }
    }
  }
}

struct ArtworkOptionView: View {
  let url: URL
  let action: () -> Void
  @State private var isLoading = true

  var body: some View {
    Button(action: action) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .empty:
          ProgressView()
            .frame(width: 120, height: 120)
            .background(Color.secondary.opacity(0.1))
        case .success(let image):
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        case .failure:
          VStack {
            Image(systemName: "exclamationmark.triangle")
            Text("Load Failed")
              .font(.caption2)
          }
          .frame(width: 120, height: 120)
          .background(Color.secondary.opacity(0.1))
        @unknown default:
          EmptyView()
        }
      }
    }
    .buttonStyle(.plain)
  }
}
