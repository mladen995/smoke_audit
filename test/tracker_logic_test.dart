import 'package:flutter_test/flutter_test.dart';
import 'package:smoke_audit/logic/tracker_logic.dart';
import 'package:smoke_audit/models/breath_log.dart';

import 'test_helpers.dart';

void main() {
  group('median / consistency', () {
    test('median of empty is null', () => expect(TrackerLogic.median(const []), isNull));
    test('median of one value', () => expect(TrackerLogic.median([3]), 3));
    test('median of odd count', () => expect(TrackerLogic.median([1, 3, 2]), 2));
    test('median of even count averages the middle two', () => expect(TrackerLogic.median([4, 1, 3, 2]), 2.5));
    test('median does not reorder the input', () {
      final List<double> v = [3, 1, 2];
      TrackerLogic.median(v);
      expect(v, [3, 1, 2]);
    });

    test('identical results are consistent', () => expect(TrackerLogic.isInconsistent([10, 10, 10]), isFalse));
    test('a spread of exactly 40% is still consistent', () => expect(TrackerLogic.isInconsistent([8, 10, 12]), isFalse));
    test('a spread above 40% is inconsistent', () => expect(TrackerLogic.isInconsistent([7, 10, 13]), isTrue));
    test('a single result is never inconsistent', () => expect(TrackerLogic.isInconsistent([10]), isFalse));
  });

  group('baseline and score', () {
    test('baseline is the median of the newest 3 baseline-session tests', () {
      final logs = [
        makeLog(id: 'a', at: DateTime.utc(2026, 10, 1), kind: LogKind.baselineSession, seconds: 20),
        makeLog(id: 'b', at: DateTime.utc(2026, 10, 2), kind: LogKind.baselineSession, seconds: 10),
        makeLog(id: 'c', at: DateTime.utc(2026, 10, 3), kind: LogKind.baselineSession, seconds: 12),
        makeLog(id: 'd', at: DateTime.utc(2026, 10, 4), kind: LogKind.baselineSession, seconds: 14),
      ];
      // newest three are 14, 12, 10
      expect(TrackerLogic.baselineSeconds(logs), 12);
    });

    test('baseline ignores ordinary tests and empty entries', () {
      final logs = [
        makeLog(id: 'a', at: DateTime.utc(2026, 10, 1), seconds: 50),
        makeLog(id: 'b', at: DateTime.utc(2026, 10, 2), kind: LogKind.baselineSession, seconds: 0),
      ];
      expect(TrackerLogic.baselineSeconds(logs), isNull);
    });

    test('current value uses the newest 3 tests inside the 30 day window', () {
      final DateTime now = DateTime.utc(2026, 11, 1);
      final logs = [
        makeLog(id: 'a', at: now.subtract(const Duration(days: 1)), seconds: 10),
        makeLog(id: 'b', at: now.subtract(const Duration(days: 2)), seconds: 12),
        makeLog(id: 'c', at: now.subtract(const Duration(days: 3)), seconds: 14),
        makeLog(id: 'd', at: now.subtract(const Duration(days: 4)), seconds: 100), // 4th newest: ignored
        makeLog(id: 'e', at: now.subtract(const Duration(days: 40)), seconds: 1), // outside window
      ];
      expect(TrackerLogic.currentSeconds(logs, {TestContext.standardBaseline}, now), 12);
    });

    test('current value only looks at the requested contexts', () {
      final DateTime now = DateTime.utc(2026, 11, 1);
      final logs = [
        makeLog(id: 'a', at: now.subtract(const Duration(days: 1)), seconds: 10),
        makeLog(id: 'b', at: now.subtract(const Duration(days: 1)), context: TestContext.postExposure, seconds: 6),
      ];
      expect(TrackerLogic.currentSeconds(logs, {TestContext.postExposure}, now), 6);
    });

    test('score is 100 at baseline, above 100 when better', () {
      expect(TrackerLogic.scoreFor(10, 10), 100);
      expect(TrackerLogic.scoreFor(12, 10), 120);
      expect(TrackerLogic.scoreFor(9, 10), 90);
      expect(TrackerLogic.scoreFor(10.4, 10), 104);
    });

    test('score is null without data or with a zero baseline', () {
      expect(TrackerLogic.scoreFor(null, 10), isNull);
      expect(TrackerLogic.scoreFor(10, null), isNull);
      expect(TrackerLogic.scoreFor(10, 0), isNull);
    });
  });

  group('streaks', () {
    final DateTime quit = DateTime.utc(2026, 10, 1);

    test('relapse contexts', () {
      expect(TrackerLogic.isRelapseContext(TestContext.relapseSlip), isTrue);
      expect(TrackerLogic.isRelapseContext(TestContext.afterSmoking), isTrue);
      expect(TrackerLogic.isRelapseContext(TestContext.postExposure), isFalse);
      expect(TrackerLogic.isRelapseContext(TestContext.standardBaseline), isFalse);
    });

    test('anchor is the latest relapse; secondhand exposure does not reset it', () {
      final logs = [
        makeLog(id: 'a', at: DateTime.utc(2026, 10, 10), context: TestContext.relapseSlip),
        makeLog(id: 'b', at: DateTime.utc(2026, 10, 20), context: TestContext.afterSmoking, seconds: 5),
        makeLog(id: 'c', at: DateTime.utc(2026, 10, 25), context: TestContext.postExposure, seconds: 5),
        makeLog(id: 'd', at: DateTime.utc(2026, 9, 20), context: TestContext.relapseSlip), // before quit date
      ];
      expect(TrackerLogic.streakAnchor(quit, logs), DateTime.utc(2026, 10, 20));
      expect(TrackerLogic.streakAnchor(quit, const []), quit);
    });

    test('elapsed time counts from the anchor', () {
      final logs = [makeLog(id: 'b', at: DateTime.utc(2026, 10, 20), context: TestContext.afterSmoking)];
      expect(TrackerLogic.streakElapsed(quit, logs, DateTime.utc(2026, 10, 21, 12)), const Duration(hours: 36));
    });

    test('a quit date in the future shows zero', () {
      expect(TrackerLogic.streakElapsed(DateTime.utc(2026, 12, 1), const [], DateTime.utc(2026, 11, 1)), Duration.zero);
      expect(TrackerLogic.longestStreak(DateTime.utc(2026, 12, 1), const [], DateTime.utc(2026, 11, 1)), Duration.zero);
    });

    test('longest streak finds the biggest gap, including the current one', () {
      final logs = [
        makeLog(id: 'a', at: DateTime.utc(2026, 10, 4), context: TestContext.relapseSlip), // 3 days
        makeLog(id: 'b', at: DateTime.utc(2026, 10, 14), context: TestContext.relapseSlip), // 10 days
      ];
      expect(TrackerLogic.longestStreak(quit, logs, DateTime.utc(2026, 10, 17)), const Duration(days: 10));
    });

    test('longest streak with no relapse is the whole time since quitting', () {
      expect(TrackerLogic.longestStreak(quit, const [], DateTime.utc(2026, 10, 8)), const Duration(days: 7));
    });
  });

  group('urges and insights', () {
    test('urges beaten excludes the shield that is still running', () {
      final logs = [
        for (int i = 0; i < 3; i++)
          makeLog(id: 'm$i', at: DateTime.utc(2026, 10, 1 + i), kind: LogKind.cravingMarker, context: TestContext.cravingThreat),
      ];
      expect(TrackerLogic.urgesBeaten(logs, shieldActive: false), 3);
      expect(TrackerLogic.urgesBeaten(logs, shieldActive: true), 2);
      expect(TrackerLogic.urgesBeaten(const [], shieldActive: true), 0);
    });

    test('slip-ups count relapse and after-smoking, not secondhand exposure', () {
      final logs = [
        makeLog(id: 'a', at: DateTime.utc(2026, 10, 2), kind: LogKind.userSlip, context: TestContext.relapseSlip),
        makeLog(id: 'b', at: DateTime.utc(2026, 10, 3), context: TestContext.afterSmoking, seconds: 4),
        makeLog(id: 'c', at: DateTime.utc(2026, 10, 4), context: TestContext.postExposure, seconds: 4),
      ];
      expect(TrackerLogic.slipUps(logs), 2);
    });

    test('time buckets', () {
      const expected = {
        0: 'late night', 4: 'late night', 5: 'morning', 10: 'morning', 11: 'midday', 14: 'midday',
        15: 'afternoon', 18: 'afternoon', 19: 'evening', 23: 'evening',
      };
      expected.forEach((hour, bucket) => expect(TrackerLogic.timeBucket(hour), bucket, reason: 'hour $hour'));
    });

    BreathLog urge(int n, int hour) =>
        makeLog(id: 'u$n', at: DateTime(2026, 10, 1 + n, hour), kind: LogKind.cravingMarker, context: TestContext.cravingThreat);

    test('no peak with fewer than 5 events', () {
      expect(TrackerLogic.peakUrge([for (int i = 0; i < 4; i++) urge(i, 8)]), isNull);
    });

    test('a peak needs at least 40% of the events in one bucket', () {
      final peak = TrackerLogic.peakUrge([urge(0, 8), urge(1, 9), urge(2, 10), urge(3, 12), urge(4, 16)]);
      expect(peak, isNotNull);
      expect(peak!.bucket, 'morning');
      expect(peak.count, 3);
      expect(peak.total, 5);

      // one in every bucket: 20% each, so no peak
      expect(TrackerLogic.peakUrge([urge(0, 8), urge(1, 12), urge(2, 16), urge(3, 20), urge(4, 2)]), isNull);
    });
  });

  group('savings', () {
    test('cigarettes avoided', () {
      expect(TrackerLogic.cigarettesAvoided(const Duration(hours: 36), 20), 30);
      expect(TrackerLogic.cigarettesAvoided(const Duration(hours: 12), 10), 5);
      expect(TrackerLogic.cigarettesAvoided(Duration.zero, 10), 0);
    });

    test('money saved assumes packs of 20', () {
      expect(TrackerLogic.moneySaved(30, 10.0), 15.0);
    });
  });
}
