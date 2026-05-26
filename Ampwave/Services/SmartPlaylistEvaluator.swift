//
//  SmartPlaylistEvaluator.swift
//  Ampwave
//

import Foundation

enum SmartPlaylistEvaluator {

  // MARK: - Public API

  /// Evaluates `rules` against `allSongs` and returns matching songs, with limits applied.
  ///
  /// **Grouping semantics:**
  /// Rules are grouped by `field`. Within a group the `connector` on each rule (except the
  /// first in the group) is used to AND/OR that rule with the accumulated group result.
  /// All field groups are AND'd together — cross-group logic is not configurable.
  static func evaluate(
    songs allSongs: [LibrarySong],
    rules: SmartPlaylistRules,
    stats: [UUID: SongPlayStatistics]
  ) -> [LibrarySong] {

    guard !rules.rules.isEmpty else { return allSongs }

    let groups = fieldGroups(from: rules.rules)

    var matched = allSongs.filter { song in
      // Every field group must pass (AND between groups)
      groups.allSatisfy { groupRules in
        evaluateGroup(groupRules, song: song, stats: stats[song.id])
      }
    }

    if rules.limitEnabled && rules.limitCount > 0 {
      matched = applyLimit(matched, count: rules.limitCount, by: rules.limitBy, stats: stats)
    }

    return matched
  }

  // MARK: - Field grouping helper (also used by the UI)

  /// Returns rules grouped by field, preserving first-occurrence order of each field.
  static func fieldGroups(from rules: [SmartRule]) -> [[SmartRule]] {
    var fieldOrder: [RuleField] = []
    var buckets: [RuleField: [SmartRule]] = [:]
    for rule in rules {
      if buckets[rule.field] == nil {
        fieldOrder.append(rule.field)
        buckets[rule.field] = []
      }
      buckets[rule.field]!.append(rule)
    }
    return fieldOrder.compactMap { buckets[$0] }
  }

  // MARK: - Group evaluation

  /// Evaluates one field group for a single song using the connectors stored on each rule.
  /// The connector on the first rule is ignored.
  private static func evaluateGroup(
    _ groupRules: [SmartRule],
    song: LibrarySong,
    stats: SongPlayStatistics?
  ) -> Bool {
    var result = matches(song: song, rule: groupRules[0], stats: stats)
    for rule in groupRules.dropFirst() {
      let r = matches(song: song, rule: rule, stats: stats)
      switch rule.connector {
      case .and: result = result && r
      case .or:  result = result || r
      }
    }
    return result
  }

  // MARK: - Single rule matching

  private static func matches(
    song: LibrarySong,
    rule: SmartRule,
    stats: SongPlayStatistics?
  ) -> Bool {
    switch rule.field {
    case .artist:    return matchString(song.artist,        op: rule.operation, value: rule.value)
    case .album:     return matchString(song.album ?? "",   op: rule.operation, value: rule.value)
    case .genre:     return matchString(song.genre ?? "",   op: rule.operation, value: rule.value)
    case .year:      return matchInt(song.year ?? 0,        op: rule.operation, value: rule.value)
    case .playCount: return matchInt(stats?.playCount ?? 0, op: rule.operation, value: rule.value)
    case .rating:    return matchInt(stats?.userRating ?? 0,op: rule.operation, value: rule.value)
    case .duration:  return matchDouble(song.duration,      op: rule.operation, value: rule.value)
    case .lastPlayed:return matchDate(stats?.lastPlayedAt,  op: rule.operation, value: rule.value)
    }
  }

  // MARK: - Type matchers

  private static func matchString(_ actual: String, op: RuleOperation, value: String) -> Bool {
    switch op {
    case .is_:            return actual.localizedCaseInsensitiveCompare(value) == .orderedSame
    case .isNot:          return actual.localizedCaseInsensitiveCompare(value) != .orderedSame
    case .contains:       return actual.localizedCaseInsensitiveContains(value)
    case .doesNotContain: return !actual.localizedCaseInsensitiveContains(value)
    case .greaterThan, .lessThan, .inTheLast: return false
    }
  }

  private static func matchInt(_ actual: Int, op: RuleOperation, value: String) -> Bool {
    guard let rhs = Int(value) else { return false }
    switch op {
    case .is_:        return actual == rhs
    case .isNot:      return actual != rhs
    case .greaterThan:return actual > rhs
    case .lessThan:   return actual < rhs
    case .contains, .doesNotContain, .inTheLast: return false
    }
  }

  private static func matchDouble(_ actual: Double, op: RuleOperation, value: String) -> Bool {
    guard let rhs = Double(value) else { return false }
    switch op {
    case .is_:        return actual == rhs
    case .isNot:      return actual != rhs
    case .greaterThan:return actual > rhs
    case .lessThan:   return actual < rhs
    case .contains, .doesNotContain, .inTheLast: return false
    }
  }

  private static func matchDate(_ actual: Date?, op: RuleOperation, value: String) -> Bool {
    switch op {
    case .inTheLast:
      guard let days = Double(value), let date = actual else { return false }
      return date >= Date().addingTimeInterval(-days * 86_400)
    case .greaterThan:   // "played more than N days ago"
      guard let days = Double(value), let date = actual else { return false }
      return date < Date().addingTimeInterval(-days * 86_400)
    case .lessThan:      // "played less than N days ago"
      guard let days = Double(value), let date = actual else { return false }
      return date > Date().addingTimeInterval(-days * 86_400)
    case .is_:    return actual != nil
    case .isNot:  return actual == nil
    case .contains, .doesNotContain: return false
    }
  }

  // MARK: - Limit

  private static func applyLimit(
    _ songs: [LibrarySong],
    count: Int,
    by limitBy: LimitSort,
    stats: [UUID: SongPlayStatistics]
  ) -> [LibrarySong] {
    var sorted: [LibrarySong]
    switch limitBy {
    case .random:        sorted = songs.shuffled()
    case .recentlyAdded: sorted = songs.sorted { $0.importedDate > $1.importedDate }
    case .recentlyPlayed:
      sorted = songs.sorted {
        (stats[$0.id]?.lastPlayedAt ?? .distantPast) > (stats[$1.id]?.lastPlayedAt ?? .distantPast)
      }
    case .mostPlayed:
      sorted = songs.sorted { (stats[$0.id]?.playCount ?? 0) > (stats[$1.id]?.playCount ?? 0) }
    case .alphabetical:
      sorted = songs.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
    return Array(sorted.prefix(count))
  }
}
