//
//  SmartPlaylistEvaluator.swift
//  Ampwave
//

import Foundation

/// The single source of truth for smart playlist matching.
///
/// PlaylistManager used to carry a second, subtly different implementation, so
/// the "N songs match" preview could disagree with the playlist you actually
/// got. Everything routes through here now.
enum SmartPlaylistEvaluator {

  // MARK: - Public API

  /// Evaluates `rules` against `allSongs` and returns matching songs, with limits applied.
  ///
  /// **Grouping semantics:**
  /// Rules are grouped by `field`. Within a group the `connector` on each rule (except the
  /// first in the group) is used to AND/OR that rule with the accumulated group result.
  /// `rules.matchMode` then decides whether every group must pass or just one.
  static func evaluate(
    songs allSongs: [LibrarySong],
    rules: SmartPlaylistRules,
    stats: [UUID: SongPlayStatistics]
  ) -> [LibrarySong] {

    // No rules means no filter, which previously matched the *entire library*.
    // A smart playlist that quietly swallows every song is never what was
    // wanted, so an empty ruleset matches nothing instead.
    guard !rules.rules.isEmpty else { return [] }

    let groups = fieldGroups(from: rules.rules)

    let matched = allSongs.filter { song in
      let songStats = stats[song.id]
      switch rules.matchMode {
      case .all:
        return groups.allSatisfy { evaluateGroup($0, song: song, stats: songStats) }
      case .any:
        return groups.contains { evaluateGroup($0, song: song, stats: songStats) }
      }
    }

    return applyLimitIfNeeded(matched, rules: rules, stats: stats)
  }

  private static func applyLimitIfNeeded(
    _ songs: [LibrarySong],
    rules: SmartPlaylistRules,
    stats: [UUID: SongPlayStatistics]
  ) -> [LibrarySong] {
    // A limit of zero used to wipe the playlist. Treat it as "no limit set".
    guard rules.limitEnabled, rules.limitCount > 0 else { return songs }
    return applyLimit(songs, count: rules.limitCount, by: rules.limitBy, stats: stats)
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
    guard let first = groupRules.first else { return true }
    var result = matches(song: song, rule: first, stats: stats)
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
    case .title:      return matchString(song.title,          op: rule.operation, value: rule.value)
    case .artist:     return matchString(song.artist,         op: rule.operation, value: rule.value)
    case .album:      return matchString(song.album ?? "",    op: rule.operation, value: rule.value)
    case .genre:      return matchString(song.genre ?? "",    op: rule.operation, value: rule.value)
    case .year:       return matchInt(song.year ?? 0,         op: rule.operation, value: rule.value)
    case .playCount:  return matchInt(stats?.playCount ?? 0,  op: rule.operation, value: rule.value)
    case .skipCount:  return matchInt(stats?.skipCount ?? 0,  op: rule.operation, value: rule.value)
    case .rating:     return matchInt(stats?.userRating ?? 0, op: rule.operation, value: rule.value)
    case .duration:   return matchDouble(song.duration,       op: rule.operation, value: rule.value)
    case .lastPlayed: return matchDate(stats?.lastPlayedAt,   op: rule.operation, value: rule.value)
    case .dateAdded:  return matchDate(song.importedDate,     op: rule.operation, value: rule.value)
    case .liked:      return matchBool(stats?.isLiked ?? false, op: rule.operation, value: rule.value)
    }
  }

  // MARK: - Type matchers

  private static func matchString(_ actual: String, op: RuleOperation, value: String) -> Bool {
    switch op {
    case .is_:            return actual.localizedCaseInsensitiveCompare(value) == .orderedSame
    case .isNot:          return actual.localizedCaseInsensitiveCompare(value) != .orderedSame
    case .contains:       return actual.localizedCaseInsensitiveContains(value)
    case .doesNotContain: return !actual.localizedCaseInsensitiveContains(value)
    case .greaterThan, .lessThan, .inTheLast, .notInTheLast: return false
    }
  }

  private static func matchInt(_ actual: Int, op: RuleOperation, value: String) -> Bool {
    guard let rhs = Int(value.trimmingCharacters(in: .whitespaces)) else { return false }
    switch op {
    case .is_:         return actual == rhs
    case .isNot:       return actual != rhs
    case .greaterThan: return actual > rhs
    case .lessThan:    return actual < rhs
    case .contains, .doesNotContain, .inTheLast, .notInTheLast: return false
    }
  }

  private static func matchDouble(_ actual: Double, op: RuleOperation, value: String) -> Bool {
    guard let rhs = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
    switch op {
    case .is_:         return abs(actual - rhs) < 0.5
    case .isNot:       return abs(actual - rhs) >= 0.5
    case .greaterThan: return actual > rhs
    case .lessThan:    return actual < rhs
    case .contains, .doesNotContain, .inTheLast, .notInTheLast: return false
    }
  }

  /// Date fields compare in "days ago". `is`/`is not` ask whether the date exists
  /// at all, which is how you build "never played".
  private static func matchDate(_ actual: Date?, op: RuleOperation, value: String) -> Bool {
    switch op {
    case .is_:   return actual != nil
    case .isNot: return actual == nil
    case .contains, .doesNotContain: return false
    case .inTheLast, .notInTheLast, .greaterThan, .lessThan:
      guard let days = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
      guard let date = actual else {
        // A song that has never been played is not "in the last N days", but it
        // *is* outside that window.
        return op == .notInTheLast || op == .greaterThan
      }
      let cutoff = Date().addingTimeInterval(-days * 86_400)
      switch op {
      case .inTheLast, .lessThan: return date >= cutoff   // more recent than the cutoff
      default:                    return date < cutoff    // older than the cutoff
      }
    }
  }

  private static func matchBool(_ actual: Bool, op: RuleOperation, value: String) -> Bool {
    let expected = (value as NSString).boolValue || value.localizedCaseInsensitiveCompare("yes") == .orderedSame
    switch op {
    case .is_:   return actual == expected
    case .isNot: return actual != expected
    default:     return false
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
