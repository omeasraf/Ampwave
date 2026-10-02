//
//  BackstageView.swift
//  Ampwave
//
//  Rich song and album credits sourced from embedded tags, MusicKit, and
//  MusicBrainz recording/work relationships.
//

internal import SwiftUI

struct BackstageView: View {
  private let title: String
  private let subtitle: String
  private let artworkPath: String?
  private let songs: [LibrarySong]

  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager
  @State private var isRefreshing = false
  @State private var completedLookups = 0
  @State private var refreshRevision = 0
  @State private var selectedContributor: BackstageContributor?

  init(song: LibrarySong) {
    title = song.title
    subtitle = song.artist
    artworkPath = song.effectiveArtworkPath
    songs = [song]
  }

  init(album: Album, songs: [LibrarySong]) {
    title = album.name
    subtitle = album.artist ?? "Album credits"
    artworkPath = album.artworkPath ?? songs.first?.effectiveArtworkPath
    self.songs = songs
  }

  private var isAlbum: Bool { songs.count > 1 }

  private var credits: [BackstageCredit] {
    _ = refreshRevision
    return BackstageCredit.merged(songs.map(\.backstageCredits))
  }

  private var contributors: [BackstageContributor] {
    _ = refreshRevision
    return backstageContributors(from: songs)
  }

  private var hasOnlineCredits: Bool {
    credits.contains { credit in
      credit.sources.contains(.appleMusic) || credit.sources.contains(.musicBrainz)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 20) {
          hero

          if isRefreshing {
            progressCard
          }

          ForEach(BackstageCreditCategory.allCases, id: \.self) { category in
            let matching = contributors.filter { $0.categories.contains(category) }
            if !matching.isEmpty {
              creditSection(category: category, contributors: matching)
            }
          }

          sourceFooter
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
      }
      .background(backdrop)
      .navigationTitle("Backstage")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await refreshCredits(force: true) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isRefreshing)
          .accessibilityLabel("Refresh credits")
        }
      }
      .sheet(item: $selectedContributor) { contributor in
        BackstageContributorView(contributor: contributor)
      }
      .task {
        guard songs.contains(where: { !$0.backstageMetadataCheckAttempted }) else { return }
        await refreshCredits(force: false)
      }
    }
  }

  private var hero: some View {
    VStack(spacing: 14) {
      ZStack(alignment: .bottomTrailing) {
        AlbumArtworkView(artworkPath: artworkPath, size: 150, cornerRadius: 24)
          .shadow(color: themeManager.accentColor.opacity(0.24), radius: 24, y: 10)

        Image(systemName: "person.2.fill")
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 42, height: 42)
          .background(themeManager.accentColor, in: Circle())
          .overlay(Circle().stroke(themeManager.backgroundColor, lineWidth: 4))
      }

      VStack(spacing: 5) {
        Text(title)
          .font(.system(size: 25, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
          .lineLimit(2)
        Text(subtitle)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      HStack(spacing: 8) {
        backstagePill("\(contributors.count) contributor\(contributors.count == 1 ? "" : "s")", icon: "person.2")
        if isAlbum {
          backstagePill("\(songs.count) tracks", icon: "music.note.list")
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 18)
  }

  private var progressCard: some View {
    HStack(spacing: 12) {
      ProgressView()
        .tint(themeManager.accentColor)
      VStack(alignment: .leading, spacing: 3) {
        Text("Opening the liner notes…")
          .font(.system(size: 15, weight: .semibold))
        Text("Checking Apple Music, then filling gaps with MusicBrainz \(completedLookups)/\(songs.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
    .background(themeManager.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func creditSection(
    category: BackstageCreditCategory,
    contributors: [BackstageContributor]
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(category.displayName, systemImage: category.systemImage)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .foregroundStyle(themeManager.accentColor)

      VStack(spacing: 0) {
        ForEach(Array(contributors.enumerated()), id: \.element.id) { index, contributor in
          Button {
            selectedContributor = contributor
          } label: {
            contributorRow(contributor, category: category)
          }
          .buttonStyle(.plain)

          if index < contributors.count - 1 {
            Divider().padding(.leading, 58)
          }
        }
      }
      .background(themeManager.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }

  private func contributorRow(
    _ contributor: BackstageContributor,
    category: BackstageCreditCategory
  ) -> some View {
    HStack(spacing: 12) {
      Text(contributor.initials)
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(themeManager.accentColor)
        .frame(width: 38, height: 38)
        .background(themeManager.accentColor.opacity(0.14), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(contributor.name)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(contributor.roles(in: category).joined(separator: " · "))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 8)

      if isAlbum, contributor.songIDs.count > 1 {
        Text("\(contributor.songIDs.count)")
          .font(.caption.weight(.bold))
          .foregroundStyle(themeManager.accentColor)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(themeManager.accentColor.opacity(0.12), in: Capsule())
      }
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  private var sourceFooter: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        let sources = Set(credits.flatMap(\.sources))
        ForEach(BackstageCreditSource.allCases.filter(sources.contains), id: \.self) { source in
          Text(source.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.11), in: Capsule())
        }
      }

      Text(
        hasOnlineCredits
          ? "Credits are matched from available catalog data and may vary by release."
          : "Showing credits found in your files. Refresh to look for expanded catalog credits."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding(.top, 2)
  }

  private func backstagePill(_ text: String, icon: String) -> some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(.secondary.opacity(0.11), in: Capsule())
  }

  private var backdrop: some View {
    ZStack {
      themeManager.backgroundColor.ignoresSafeArea()
      LinearGradient(
        colors: [themeManager.accentColor.opacity(0.13), .clear],
        startPoint: .top,
        endPoint: .center
      )
      .ignoresSafeArea()
    }
  }

  @MainActor
  private func refreshCredits(force: Bool) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    completedLookups = 0
    defer { isRefreshing = false }

    for song in songs {
      guard !Task.isCancelled else { return }
      if force || !song.backstageMetadataCheckAttempted {
        _ = await MetadataService.shared.enrichBackstageCredits(for: song, force: force)
      }
      completedLookups += 1
      refreshRevision &+= 1
    }
  }
}

/// Compact liner notes shown directly after an album's tracks. The album page
/// already supplies the release artwork and title, so this intentionally skips
/// the full-screen Backstage hero and leads with the useful credits themselves.
struct AlbumBackstageSection: View {
  let songs: [LibrarySong]

  @Environment(ThemeManager.self) private var themeManager
  @State private var expandedCategories: Set<BackstageCreditCategory> = []
  @State private var isRefreshing = false
  @State private var refreshRevision = 0
  @State private var selectedContributor: BackstageContributor?

  private var credits: [BackstageCredit] {
    _ = refreshRevision
    return BackstageCredit.merged(songs.map(\.backstageCredits))
  }

  private var contributors: [BackstageContributor] {
    _ = refreshRevision
    return backstageContributors(from: songs)
  }

  private var visibleCategories: [BackstageCreditCategory] {
    BackstageCreditCategory.allCases.filter { category in
      contributors.contains { $0.categories.contains(category) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "person.2.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(themeManager.accentColor)
          .frame(width: 34, height: 34)
          .background(themeManager.accentColor.opacity(0.14), in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text("Album credits")
            .font(.headline)
          Text("\(contributors.count) contributor\(contributors.count == 1 ? "" : "s") across \(songs.count) track\(songs.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if isRefreshing {
          ProgressView()
            .tint(themeManager.accentColor)
        } else {
          Button {
            Task { await refreshCredits(force: true) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .foregroundStyle(themeManager.accentColor)
          .accessibilityLabel("Refresh album credits")
        }
      }

      if contributors.isEmpty {
        Text(isRefreshing ? "Looking for liner notes…" : "No album credits were found in these files.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(visibleCategories, id: \.self) { category in
          categorySection(category)
        }

        sourceSummary
      }
    }
    .padding(.vertical, 4)
    .sheet(item: $selectedContributor) { contributor in
      BackstageContributorView(contributor: contributor)
    }
    .task {
      guard songs.contains(where: { !$0.backstageMetadataCheckAttempted }) else { return }
      await refreshCredits(force: false)
    }
  }

  private func categorySection(_ category: BackstageCreditCategory) -> some View {
    let matching = contributors.filter { $0.categories.contains(category) }
    let isExpanded = expandedCategories.contains(category)
    let visible = isExpanded ? matching : Array(matching.prefix(4))

    return VStack(alignment: .leading, spacing: 8) {
      Label(category.displayName, systemImage: category.systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(themeManager.accentColor)

      ForEach(visible) { contributor in
        Button {
          selectedContributor = contributor
        } label: {
          HStack(spacing: 10) {
            Text(contributor.initials)
              .font(.caption.weight(.bold))
              .foregroundStyle(themeManager.accentColor)
              .frame(width: 30, height: 30)
              .background(themeManager.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
              Text(contributor.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
              Text(contributor.roles(in: category).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      if matching.count > 4 {
        Button(isExpanded ? "Show less" : "Show all \(matching.count)") {
          withAnimation(.snappy) {
            if isExpanded {
              expandedCategories.remove(category)
            } else {
              expandedCategories.insert(category)
            }
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(themeManager.accentColor)
        .buttonStyle(.plain)
      }
    }
  }

  private var sourceSummary: some View {
    let sources = Set(credits.flatMap(\.sources))
    return HStack(spacing: 6) {
      ForEach(BackstageCreditSource.allCases.filter(sources.contains), id: \.self) { source in
        Text(source.displayName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.secondary.opacity(0.10), in: Capsule())
      }
    }
  }

  @MainActor
  private func refreshCredits(force: Bool) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    for song in songs {
      guard !Task.isCancelled else { return }
      if force || !song.backstageMetadataCheckAttempted {
        _ = await MetadataService.shared.enrichBackstageCredits(for: song, force: force)
      }
      refreshRevision &+= 1
    }
  }
}

private func backstageContributors(from songs: [LibrarySong]) -> [BackstageContributor] {
  var values: [String: BackstageContributor] = [:]

  for song in songs {
    for credit in song.backstageCredits {
      let key = credit.name
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
      var contributor = values[key] ?? BackstageContributor(name: credit.name)
      contributor.add(credit: credit, song: song)
      values[key] = contributor
    }
  }

  return values.values.sorted {
    if $0.categoryRank != $1.categoryRank { return $0.categoryRank < $1.categoryRank }
    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
  }
}

private struct BackstageContributor: Identifiable {
  let name: String
  private(set) var contributions: [BackstageContribution] = []

  var id: String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
  }

  var initials: String {
    let words = name.split(separator: " ")
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }

  var categories: Set<BackstageCreditCategory> {
    Set(contributions.map(\.credit.category))
  }

  var categoryRank: Int {
    categories.compactMap { BackstageCreditCategory.allCases.firstIndex(of: $0) }.min() ?? .max
  }

  var songIDs: Set<UUID> { Set(contributions.map(\.song.id)) }

  mutating func add(credit: BackstageCredit, song: LibrarySong) {
    let duplicate = contributions.contains {
      $0.song.id == song.id && $0.credit.id == credit.id
    }
    if !duplicate {
      contributions.append(BackstageContribution(credit: credit, song: song))
    }
  }

  func roles(in category: BackstageCreditCategory) -> [String] {
    Array(Set(contributions.filter { $0.credit.category == category }.map { $0.credit.role }))
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
}

private struct BackstageContribution: Identifiable {
  let credit: BackstageCredit
  let song: LibrarySong

  var id: String { "\(song.id.uuidString)|\(credit.id)" }
}

private struct BackstageContributorView: View {
  let contributor: BackstageContributor

  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeManager.self) private var themeManager

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 10) {
            Text(contributor.initials)
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .foregroundStyle(themeManager.accentColor)
              .frame(width: 74, height: 74)
              .background(themeManager.accentColor.opacity(0.14), in: Circle())
            Text(contributor.name)
              .font(.title2.bold())
              .multilineTextAlignment(.center)
            Text("\(contributor.songIDs.count) song\(contributor.songIDs.count == 1 ? "" : "s") in this release")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
        }
        .listRowBackground(Color.clear)

        ForEach(BackstageCreditCategory.allCases, id: \.self) { category in
          let contributions = contributor.contributions.filter { $0.credit.category == category }
          if !contributions.isEmpty {
            Section(category.displayName) {
              ForEach(contributions) { contribution in
                HStack(spacing: 12) {
                  AlbumArtworkView(
                    artworkPath: contribution.song.effectiveArtworkPath,
                    size: 44,
                    cornerRadius: 9
                  )
                  VStack(alignment: .leading, spacing: 3) {
                    Text(contribution.credit.role)
                      .font(.headline)
                    Text(contribution.song.title)
                      .font(.subheadline)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
            }
            .listRowBackground(themeManager.cardBackgroundColor)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(themeManager.backgroundColor)
      .navigationTitle("Contributor")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
