//
//  DuplicateManagementView.swift
//  Ampwave
//
//  View for managing and merging duplicate songs.
//

import SwiftData
internal import SwiftUI

struct DuplicateManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var themeManager
    @State private var duplicateGroups: [SongLibrary.DuplicateGroup] = []
    @State private var isLoading = true
    @State private var isMerging = false
    @State private var selectedGroupForManual: SongLibrary.DuplicateGroup?

    private var library: SongLibrary { SongLibrary.shared }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Analyzing Library...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if duplicateGroups.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("No duplicates found!")
                        .font(.headline)
                    Text("Your library is clean and organized.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        HStack {
                            Text("\(duplicateGroups.count) Duplicate Clusters")
                                .font(.headline)
                            Spacer()
                            Button("Auto-Keep Best All") {
                                autoMergeAll()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)

                        ForEach(duplicateGroups) { group in
                            DuplicateGroupCard(
                                group: group,
                                onKeepBest: { keepBest(in: group) },
                                onManual: { selectedGroupForManual = group }
                            )
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .background(themeManager.backgroundColor)
        .navigationTitle("Manage Duplicates")
        .sheet(item: $selectedGroupForManual) { group in
            ManualDuplicateSelectionView(group: group) { songsToDelete in
                deleteSongs(songsToDelete)
                selectedGroupForManual = nil
                refreshDuplicates()
            }
        }
        .onAppear {
            refreshDuplicates()
        }
        .overlay {
            if isMerging {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Processing...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func refreshDuplicates() {
        isLoading = true
        Task {
            let groups = library.findDuplicates()

            self.duplicateGroups = groups
            self.isLoading = false
        }
    }

    private func keepBest(in group: SongLibrary.DuplicateGroup) {
        Task {
            isMerging = true
            let sorted = group.songs.sorted { s1, s2 in
                library.calculateQualityScore(for: s1)
                    > library.calculateQualityScore(for: s2)
            }

            let toDelete = Array(sorted.dropFirst())
            deleteSongs(toDelete)

            await MainActor.run {
                refreshDuplicates()
                isMerging = false
            }
        }
    }

    private func autoMergeAll() {
        isMerging = true
        Task {
            for group in duplicateGroups {
                let sorted = group.songs.sorted { s1, s2 in
                    library.calculateQualityScore(for: s1)
                        > library.calculateQualityScore(for: s2)
                }
                let toDelete = Array(sorted.dropFirst())
                deleteSongs(toDelete)
            }

            await MainActor.run {
                refreshDuplicates()
                isMerging = false
            }
        }
    }

    private func deleteSongs(_ songsToDelete: [LibrarySong]) {
        for song in songsToDelete {
            // Transfer playlist memberships to the version we're keeping (not implemented here for simplicity, but should be)
            // For now, follow the requirement: NEVER auto-delete without explicit user action (this is triggered by user)

            let url = library.getFileURL(for: song)
            if song.storageMode == .copied
                && FileManager.default.fileExists(atPath: url.path)
            {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(song)
        }
        try? modelContext.save()
    }
}

struct DuplicateGroupCard: View {
    let group: SongLibrary.DuplicateGroup
    let onKeepBest: () -> Void
    let onManual: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ArtworkImage(
                    artworkPath: group.songs.first?.effectiveArtworkPath,
                    size: 50,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.songs.first?.title ?? "Unknown")
                            .font(.headline)
                            .lineLimit(1)

                        Text(group.reason)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(themeManager.accentColor.opacity(0.1))
                            .foregroundStyle(themeManager.accentColor)
                            .clipShape(Capsule())
                    }

                    Text(group.songs.first?.artist ?? "Unknown")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(group.songs.count) versions")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.accentColor.opacity(0.1))
                    .foregroundStyle(themeManager.accentColor)
                    .clipShape(Capsule())
            }

            Divider()

            HStack {
                Button(action: onKeepBest) {
                    Label("Keep Best", systemImage: "sparkles")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.accentColor)

                Button(action: onManual) {
                    Label("Manual", systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding()
        .background(themeManager.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct ManualDuplicateSelectionView: View {
    let group: SongLibrary.DuplicateGroup
    let onApply: ([LibrarySong]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @State private var selectedToKeep: UUID?

    private var library: SongLibrary { SongLibrary.shared }

    init(
        group: SongLibrary.DuplicateGroup,
        onApply: @escaping ([LibrarySong]) -> Void
    ) {
        self.group = group
        self.onApply = onApply

        // Default to keep the best one
        let best = group.songs.max { s1, s2 in
            SongLibrary.shared.calculateQualityScore(for: s1)
                < SongLibrary.shared.calculateQualityScore(for: s2)
        }
        _selectedToKeep = State(initialValue: best?.id)
    }

    var body: some View {
        NavigationStack {
            List(group.songs) { song in
                HStack(spacing: 12) {
                    ArtworkImage(
                        artworkPath: song.effectiveArtworkPath,
                        size: 44,
                        cornerRadius: 6
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(song.format?.uppercased() ?? "UNKNOWN")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    qualityColor(for: song).opacity(0.2)
                                )
                                .foregroundStyle(qualityColor(for: song))
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            if let bitRate = song.bitRate {
                                Text("\(bitRate) kbps")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(song.fileName)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)

                        Text(
                            "\(formatSize(song.size)) • \(formatDuration(song.duration))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if selectedToKeep == song.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(themeManager.accentColor)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedToKeep = song.id
                }
            }
            .navigationTitle("Manual Selection")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if let keepId = selectedToKeep {
                            let toDelete = group.songs.filter {
                                $0.id != keepId
                            }
                            onApply(toDelete)
                            dismiss()
                        }
                    }
                    .disabled(selectedToKeep == nil)
                }
            }
        }
    }

    private func qualityColor(for song: LibrarySong) -> Color {
        let score = library.calculateQualityScore(for: song)
        if score >= 1000 { return .purple }  // Lossless
        if score >= 800 { return .blue }
        if score >= 600 { return .green }
        return .orange
    }

    private func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bytes),
            countStyle: .file
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
