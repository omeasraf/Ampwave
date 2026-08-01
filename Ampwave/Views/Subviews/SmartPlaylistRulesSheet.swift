//
//  SmartPlaylistRulesSheet.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

// MARK: - Sheet

/// The rules editor.
///
/// Deliberately provides no `NavigationStack` of its own — the create flow
/// pushes it onto an existing stack, and nesting stacks broke the toolbar and
/// dropped the whole flow back to step one.
struct SmartRulesEditor: View {
  let title: String
  let confirmTitle: String
  let onCancel: () -> Void
  let onSave: (SmartPlaylistRules) -> Void

  @State private var rules: [SmartRule]
  @State private var limitEnabled: Bool
  @State private var limitCount: Int
  @State private var limitBy: LimitSort
  @State private var matchMode: RuleMatchMode
  @State private var previewCount: Int = 0

  private var library: SongLibrary { SongLibrary.shared }

  init(
    initialRules: SmartPlaylistRules,
    title: String = "Smart Rules",
    confirmTitle: String = "Save",
    onCancel: @escaping () -> Void,
    onSave: @escaping (SmartPlaylistRules) -> Void
  ) {
    self.title = title
    self.confirmTitle = confirmTitle
    self.onCancel = onCancel
    self.onSave = onSave
    _rules = State(initialValue: initialRules.rules)
    _limitEnabled = State(initialValue: initialRules.limitEnabled)
    _limitCount = State(initialValue: initialRules.limitCount)
    _limitBy = State(initialValue: initialRules.limitBy)
    _matchMode = State(initialValue: initialRules.matchMode)
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
      rules: rules,
      limitEnabled: limitEnabled,
      limitCount: limitCount,
      limitBy: limitBy,
      matchMode: matchMode
    )
  }

  // MARK: - Body

  var body: some View {
    Form {
      rulesSection
      limitSection
      previewSection
    }
    .navigationTitle(title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { onCancel() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(confirmTitle) { onSave(currentRulesStruct) }
          // Without at least one rule a smart playlist matches nothing, and
          // saving one would silently produce an empty list.
          .disabled(rules.isEmpty)
      }
    }
    .onChange(of: rules) { _, _ in refreshPreview() }
    .onChange(of: limitEnabled) { _, _ in refreshPreview() }
    .onChange(of: limitCount) { _, _ in refreshPreview() }
    .onChange(of: limitBy) { _, _ in refreshPreview() }
    .onChange(of: matchMode) { _, _ in refreshPreview() }
    .onAppear { refreshPreview() }
  }

  // MARK: - Rules section

  private var rulesSection: some View {
    Section {
      if fieldGroups.count > 1 {
        Picker("Match", selection: $matchMode) {
          ForEach(RuleMatchMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }

      if rules.isEmpty {
        Text("No rules yet — tap Add Rule to get started.")
          .foregroundStyle(.secondary)
          .font(.subheadline)
      } else {
        ForEach(Array(fieldGroups.enumerated()), id: \.element.field) { groupIndex, group in
          // Divider between field groups, labelled with how they combine.
          if groupIndex > 0 {
            groupDivider
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
        Text(
          matchMode == .all
            ? "A song must match every block. OR/AND applies only within the same field."
            : "A song only has to match one block. OR/AND applies only within the same field."
        )
        .font(.caption)
      }
    }
  }

  // MARK: - Sub-views

  private var groupDivider: some View {
    HStack {
      VStack { Divider() }
      Text(matchMode == .all ? "AND" : "OR")
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
    let newRule = SmartRule(
      connector: .or,
      field: field,
      operation: field.defaultOperation,
      value: field == .liked ? "true" : ""
    )

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
    previewCount = SmartPlaylistEvaluator.evaluate(
      songs: library.songs,
      rules: currentRulesStruct,
      stats: ListeningHistoryTracker.shared.statisticsBySongId()
    ).count
  }
}

// MARK: - Editing an existing smart playlist

struct SmartPlaylistRulesSheet: View {
  let playlist: Playlist

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  var body: some View {
    NavigationStack {
      SmartRulesEditor(
        initialRules: playlist.smartRules
          ?? SmartPlaylistRules(
            rules: [], limitEnabled: false, limitCount: 25, limitBy: .random),
        onCancel: { dismiss() },
        onSave: { newRules in
          playlist.smartRules = newRules
          playlist.touch()
          try? modelContext.save()
          PlaylistManager.shared.updateSmartPlaylist(playlist)
          dismiss()
        }
      )
    }
  }
}

// MARK: - Individual Rule Row

private struct RuleRowView: View {
  @Binding var rule: SmartRule

  private var validOperations: [RuleOperation] { rule.field.validOperations }

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

    case .liked:
      Picker("Loved", selection: Binding(
        get: { (rule.value as NSString).boolValue },
        set: { rule.value = $0 ? "true" : "false" }
      )) {
        Text("Loved").tag(true)
        Text("Not loved").tag(false)
      }
      .pickerStyle(.segmented)

    default:
      switch rule.field.valueKind {
      case .text:
        TextField("Value", text: $rule.value)

      case .number:
        numberField(rule.field == .year ? "e.g. 2020" : "Value")

      case .duration:
        HStack {
          numberField("Seconds")
          Text("sec").foregroundStyle(.secondary).font(.caption)
        }

      case .days:
        HStack {
          numberField("Days")
          // "is"/"is not" ask whether the date exists at all, so "days ago"
          // would be misleading there.
          if rule.operation != .is_ && rule.operation != .isNot {
            Text("days ago").foregroundStyle(.secondary).font(.caption)
          }
        }

      case .boolean:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func numberField(_ placeholder: String) -> some View {
    #if os(iOS)
      TextField(placeholder, text: $rule.value).keyboardType(.numberPad)
    #else
      TextField(placeholder, text: $rule.value)
    #endif
  }
}

// MARK: - Display name extensions
// RuleField.displayName and RuleOperation.displayName live alongside their enums.

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
