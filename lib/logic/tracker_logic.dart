// lib/logic/tracker_logic.dart
//
// All streak / baseline / score / insight calculations as plain Dart so they
// can be unit-tested without a device. Every function takes `now` explicitly.
import 'dart:math';

import '../models/breath_log.dart';

class PeakUrge {
  final String bucket;
  final int count;
  final int total;
  const PeakUrge(this.bucket, this.count, this.total);
}

class TrackerLogic {
  TrackerLogic._();

  static const int baselineTestsRequired = 3;
  static const int scoreWindowDays = 30;
  static const double inconsistentSpread = 0.4;
  static const List<String> bucketNames = ['morning', 'midday', 'afternoon', 'evening', 'late night'];

  // ───────────── basic statistics ─────────────

  /// Median of [values]; null when empty. Does not modify the input.
  static double? median(Iterable<double> values) {
    final List<double> sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;
    final int mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// True when the spread between best and worst test is more than 40% of the median.
  static bool isInconsistent(List<double> seconds) {
    if (seconds.length < 2) return false;
    final double med = median(seconds)!;
    final double spread = (seconds.reduce(max) - seconds.reduce(min)) / (med <= 0 ? 1 : med);
    return spread > inconsistentSpread;
  }

  static List<BreathLog> _newestFirst(Iterable<BreathLog> logs) {
    final List<BreathLog> list = logs.toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  // ───────────── baseline and score ─────────────

  /// Personal baseline = median of the 3 most recent guided baseline-session tests (seconds).
  static double? baselineSeconds(Iterable<BreathLog> logs) {
    final List<double> session = _newestFirst(
      logs.where((l) => l.kind == LogKind.baselineSession && l.duration.inMilliseconds > 0),
    ).take(baselineTestsRequired).map((l) => l.duration.inMilliseconds / 1000.0).toList();
    return median(session);
  }

  /// Median of the newest (up to 3) tests in [contexts] inside the scoring window (seconds).
  static double? currentSeconds(Iterable<BreathLog> logs, Set<TestContext> contexts, DateTime now) {
    final DateTime cutoff = now.subtract(const Duration(days: scoreWindowDays));
    final List<double> recent = _newestFirst(
      logs.where((l) =>
          contexts.contains(l.context) && l.duration.inMilliseconds > 0 && l.timestamp.isAfter(cutoff)),
    ).take(3).map((l) => l.duration.inMilliseconds / 1000.0).toList();
    return median(recent);
  }

  /// 100 = the user's own baseline.
  static int? scoreFor(double? seconds, double? baseline) {
    if (seconds == null || baseline == null || baseline <= 0) return null;
    return (seconds / baseline * 100).round();
  }

  // ───────────── streaks ─────────────

  static bool isRelapseContext(TestContext c) =>
      c == TestContext.relapseSlip || c == TestContext.afterSmoking;

  /// The moment the current smoke-free streak started: the later of the quit
  /// date and the most recent relapse-type entry.
  static DateTime streakAnchor(DateTime quitDate, Iterable<BreathLog> logs) {
    DateTime anchor = quitDate;
    for (final l in logs) {
      if (isRelapseContext(l.context) && l.timestamp.isAfter(anchor)) anchor = l.timestamp;
    }
    return anchor;
  }

  /// Current streak length. Zero while the quit date is still in the future.
  static Duration streakElapsed(DateTime quitDate, Iterable<BreathLog> logs, DateTime now) {
    final Duration d = now.difference(streakAnchor(quitDate, logs));
    return d.isNegative ? Duration.zero : d;
  }

  static Duration longestStreak(DateTime quitDate, Iterable<BreathLog> logs, DateTime now) {
    if (quitDate.isAfter(now)) return Duration.zero;

    final List<DateTime> points = [
      quitDate,
      ...logs
          .where((l) =>
              isRelapseContext(l.context) && l.timestamp.isAfter(quitDate) && !l.timestamp.isAfter(now))
          .map((l) => l.timestamp),
    ]..sort();
    points.add(now);

    Duration best = Duration.zero;
    for (int i = 1; i < points.length; i++) {
      final Duration d = points[i].difference(points[i - 1]);
      if (d > best) best = d;
    }
    return best;
  }

  // ───────────── urges and slip-ups ─────────────

  static Iterable<BreathLog> _urgeEvents(Iterable<BreathLog> logs) =>
      logs.where((l) => l.kind == LogKind.cravingMarker || l.kind == LogKind.userSlip);

  /// Cravings that were ridden out. The marker of a shield still running is not counted.
  static int urgesBeaten(Iterable<BreathLog> logs, {required bool shieldActive}) {
    final int markers = logs.where((l) => l.kind == LogKind.cravingMarker).length;
    return max(0, markers - (shieldActive ? 1 : 0));
  }

  /// Every relapse-type entry (declared, backdated, or a test labelled "after I smoked").
  static int slipUps(Iterable<BreathLog> logs) => logs.where((l) => isRelapseContext(l.context)).length;

  static String timeBucket(int hour) {
    if (hour >= 5 && hour < 11) return 'morning';
    if (hour >= 11 && hour < 15) return 'midday';
    if (hour >= 15 && hour < 19) return 'afternoon';
    if (hour >= 19) return 'evening';
    return 'late night';
  }

  static Map<String, int> urgeCountsByBucket(Iterable<BreathLog> logs) {
    final Map<String, int> counts = {for (final n in bucketNames) n: 0};
    for (final l in _urgeEvents(logs)) {
      final String b = timeBucket(l.timestamp.hour);
      counts[b] = (counts[b] ?? 0) + 1;
    }
    return counts;
  }

  /// The time of day when most urges happen; null unless there are at least 5
  /// events and one bucket holds 40% or more of them.
  static PeakUrge? peakUrge(Iterable<BreathLog> logs) {
    final int total = _urgeEvents(logs).length;
    if (total < 5) return null;
    final Map<String, int> counts = urgeCountsByBucket(logs);
    String? best;
    int bestCount = -1;
    for (final e in counts.entries) {
      if (e.value > bestCount) {
        best = e.key;
        bestCount = e.value;
      }
    }
    if (best == null || bestCount / total < 0.4) return null;
    return PeakUrge(best, bestCount, total);
  }

  // ───────────── savings ─────────────

  static int cigarettesAvoided(Duration elapsed, int cigarettesPerDay) =>
      (elapsed.inSeconds / 86400.0 * cigarettesPerDay).floor();

  static double moneySaved(int cigarettesAvoided, double pricePerPackOf20) =>
      cigarettesAvoided / 20.0 * pricePerPackOf20;
}
