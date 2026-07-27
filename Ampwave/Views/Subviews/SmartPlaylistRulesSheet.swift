//
//  SmartPlaylistRulesSheet.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

// MARK: - Sheet

struct SmartPlaylistRulesSheet: View {
  let playlist: Playlist

  @State private var rules: [SmartRule]
  @State private var limitEnabled: Bool
  @State private var limitCount: Int
  @State private var limitBy: LimitSort
  @State private var previewCount: Int = 0

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  private var library: SongLibrary { SongLibrary.shared }

  init(playlist: Playlist) {
    self.playlist = playlist
    let r = playlist.smartRules ?? SmartPlaylistRules(
      rules: [], limitEnabled: false, limitCount: 25, limitBy: .random)
    _rules = State(initialValue: r.rules)
    _limitEnabled = State(initialValue: r.limitEnabled)
    _limitCount = State(initialValue: r.limitCount)
    _limitBy = State(initialValue: r.limitBy)
  }

  // MARK: - Field groups (computed from flat rules array)

  /// Rules grouped by field, preserving first-occurrence order of each field.
  /// Each element is (field, indices-into-rules).
  private var fieldGroups: [(field: RuleField, indices: [Int])] {
    var order: [RuleField] = []
    var buckets: [RuleField: [Int]] = [:]
    for (i, rule) in rules.enumerated() {
      if buckets[rule.field] == nil {
        order.append(rule.field)
        buckets[rule.field] = []
      }
      buckets[rule.field]!.append(i)
    }
    return order.compactMap { f in buckets[f].map { (f, $0) } }
  }

  private var currentRulesStruct: SmartPlaylistRules {
    SmartPlaylistRules(
      rules: rules, limitEnabled: limitEnabled, limitCount: limitCount, limitBy: limitBy)
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      rulesForm
    }
  }

  private var rulesForm: some View {
    Form {
      rulesSection
      limitSection
      previewSection
    }
    .navigationTitle("Smart Rules")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
      }
    }
    .onChange(of: rules) { _, _ in refreshPreview() }
    .onChange(of: limitEnabled) { _, _ in refreshPreview() }
    .onChange(of: limitCount) { _, _ in refreshPreview() }
    .onChange(of: limitBy) { _, _ in refreshPreview() }
    .onAppear { refreshPreview() }
  }

  // MARK: - Rules section

  private var rulesSection: some View {
    Section {
      if rules.isEmpty {
        Text("No rules yet — tap Add Rule to get started.")
          .foregroundStyle(.secondary)
          .font(.subheadline)
      } else {
        ForEach(Array(fieldGroups.enumerated()), id: \.element.field) { groupIndex, group in
          // "AND" divider between field groups (not shown before the first group)
          if groupIndex > 0 {
            andDivider
          }

          // Rules within the group
          ForEach(Array(group.indices.enumerated()), id: \.element) { posInGroup, ruleIndex in
            VStack(alignment: .leading, spacing: 4) {
              // OR/AND picker between rules of the same field (not before the first in the group)
              if posInGroup > 0 {
                connectorPicker(ruleIndex: ruleIndex)
              }
              RuleRowView(rule: $rules[ruleIndex])
            }
            .padding(.vertical, 2)
          }
        }
      }

      addRuleMenu
    } header: {
      Text("Rules")
    } footer: {
      if fieldGroups.count > 1 {
        Text("Each field block is AND'd together. OR/AND applies only within the same field.")
          .font(.caption)
      }
    }
  }

  // MARK: - Sub-views

  private var andDivider: some View {
    HStack {
      VStack { Divider() }
      Text("AND")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
      VStack { Divider() }
    }
    .padding(.vertical, 2)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
  }

  private func connectorPicker(ruleIndex: Int) -> some View {
    Picker("", selection: $rules[ruleIndex].connector) {
      Text("OR").tag(RuleConnector.or)
      Text("AND").tag(RuleConnector.and)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  private var addRuleMenu: some View {
    Menu {
      ForEach(RuleField.allCases, id: \.self) { field in
        Button(field.displayName) {
          addRule(for: field)
        }
      }
    } label: {
      Label("Add Rule", systemImage: "plus.circle.fill")
    }
  }

  // MARK: - Limit section

  private var limitSection: some View {
    Section {
      Toggle("Limit to", isOn: $limitEnabled)
      if limitEnabled {
        Stepper("\(limitCount) songs", value: $limitCount, in: 1...500)
        Picker("Selected by", selection: $limitBy) {
          ForEach(LimitSort.allCases, id: \.self) { sort in
            Text(sort.displayName).tag(sort)
          }
        }
      }
    } header: {
      Text("Limit")
    }
  }

  // MARK: - Preview section

  private var previewSection: some View {
    Section {
      HStack {
        Image(systemName: "music.note.list").foregroundStyle(.secondary)
        Text("\(previewCount) song\(previewCount == 1 ? "" : "s") match")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Preview")
    }
  }

  // MARK: - Actions

  /// Adds a new rule for `field`, inserted right after the last existing rule of that field
  /// (so the same-field group stays contiguous), or at the end if none exists.
  private func addRule(for field: RuleField) {
    let defaultOp: RuleOperation
    switch field {
    case .artist, .album, .genre: defaultOp = .contains
    case .year, .playCount, .rating, .duration: defaultOp = .greaterThan
    case .lastPlayed: defaultOp = .inTheLast
    }
    let newRule = SmartRule(connector: .or, field: field, operation: defaultOp, value: "")

    // Insert after the last rule of the same field, or append
    if let lastIdx = rules.indices.last(where: { rules[$0].field == field }) {
      rules.insert(newRule, at: lastIdx + 1)
    } else {
      rules.append(newRule)
    }
  }

  private func deleteRule(at ruleIndex: Int) {
    rules.remove(at: ruleIndex)
  }

  private func refreshPreview() {
    let r = currentRulesStruct
    let allSongs = library.songs
    let statsDict = buildStatsDict()
    previewCount = SmartPlaylistEvaluator.evaluate(songs: allSongs, rules: r, stats: statsDict).count
  }

  private func save() {
    playlist.smartRules = currentRulesStruct
    playlist.touch()
    try? modelContext.save()
    PlaylistManager.shared.updateSmartPlaylist(playlist)
    dismiss()
  }

  private func buildStatsDict() -> [UUID: SongPlayStatistics] {
    guard let all = try? modelContext.fetch(FetchDescriptor<SongPlayStatistics>()) else { return [:] }
    return Dictionary(uniqueKeysWithValues: all.map { ($0.songId, $0) })
  }
}

// MARK: - Individual Rule Row

private struct RuleRowView: View {
  @Binding var rule: SmartRule

  private var validOperations: [RuleOperation] {
    switch rule.field {
    case .artist, .album, .genre:
      return [.contains, .doesNotContain, .is_, .isNot]
    case .year, .playCount, .rating, .duration:
      return [.greaterThan, .lessThan, .is_, .isNot]
    case .lastPlayed:
      return [.inTheLast, .greaterThan, .lessThan, .is_, .isNot]
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        // Field picker is hidden — field is fixed per group; shown only for clarity
        Text(rule.field.displayName)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)

        Spacer()

        Picker("", selection: $rule.operation) {
          ForEach(validOperations, id: \.self) { op in
            Text(op.displayName).tag(op)
          }
        }
        .labelsHidden()
        .onChange(of: rule.field) { _, _ in
          if !validOperations.contains(rule.operation) {
            rule.operation = validOperations[0]
          }
          rule.value = ""
        }
      }

      ruleValueInput
        .textFieldStyle(.roundedBorder)
    }
  }

  @ViewBuilder
  private var ruleValueInput: some View {
    switch rule.field {
    case .artist, .album, .genre:
      TextField("Value", text: $rule.value)

    case .year:
      #if os(iOS)
        TextField("e.g. 2020", text: $rule.value)
          .keyboardType(.numberPad)
      #else
        TextField("e.g. 2020", text: $rule.value)
      #endif

    case .playCount:
      #if os(iOS)
        TextField("Play count", text: $rule.value)
          .keyboardType(.numberPad)
      #else
        TextField("Play count", text: $rule.value)
      #endif

    case .rating:
      Picker("Rating", selection: Binding(
        get: { Int(rule.value) ?? 0 },
        set: { rule.value = String($0) }
      )) {
        Text("Any").tag(0)
        ForEach(1...5, id: \.self) { n in
          Text(String(repeating: "★", count: n)).tag(n)
        }
      }
      .pickerStyle(.segmented)

    case .duration:
      HStack {
        #if os(iOS)
          TextField("Seconds", text: $rule.value).keyboardType(.numberPad)
        #else
          TextField("Seconds", text: $rule.value)
        #endif
        Text("sec").foregroundStyle(.secondary).font(.caption)
      }

    case .lastPlayed:
      HStack {
        #if os(iOS)
          TextField("Days", text: $rule.value).keyboardType(.numberPad)
        #else
          TextField("Days", text: $rule.value)
        #endif
        Text(rule.operation == .is_ || rule.operation == .isNot ? "" : "days ago")
          .foregroundStyle(.secondary).font(.caption)
      }
    }
  }
}

// MARK: - Display name extensions

extension RuleField {
  var displayName: String {
    switch self {
    case .artist:    return "Artist"
    case .album:     return "Album"
    case .genre:     return "Genre"
    case .year:      return "Year"
    case .playCount: return "Play Count"
    case .lastPlayed:return "Last Played"
    case .rating:    return "Rating"
    case .duration:  return "Duration"
    }
  }
}

extension RuleOperation {
  var displayName: String {
    switch self {
    case .is_:            return "is"
    case .isNot:          return "is not"
    case .contains:       return "contains"
    case .doesNotContain: return "doesn't contain"
    case .greaterThan:    return "greater than"
    case .lessThan:       return "less than"
    case .inTheLast:      return "in the last"
    }
  }
}

extension LimitSort {
  var displayName: String {
    switch self {
    case .random:        return "Random"
    case .recentlyAdded: return "Recently Added"
    case .recentlyPlayed:return "Recently Played"
    case .mostPlayed:    return "Most Played"
    case .alphabetical:  return "Alphabetical"
    }
  }
}
