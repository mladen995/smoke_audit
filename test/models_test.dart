import 'package:flutter_test/flutter_test.dart';
import 'package:smoke_audit/models/app_settings.dart';
import 'package:smoke_audit/models/breath_log.dart';
import 'package:smoke_audit/models/user_profile.dart';

import 'test_helpers.dart';

void main() {
  group('BreathLog', () {
    test('survives a JSON round trip', () {
      final log = makeLog(
        id: 'x1',
        at: DateTime.utc(2026, 10, 5, 8, 30),
        kind: LogKind.baselineSession,
        context: TestContext.afterSmoking,
        seconds: 12.5,
        lat: 41.8781,
        lng: -87.6298,
      );
      final copy = BreathLog.fromJson(log.toJson());
      expect(copy.id, 'x1');
      expect(copy.kind, LogKind.baselineSession);
      expect(copy.context, TestContext.afterSmoking);
      expect(copy.duration, const Duration(milliseconds: 12500));
      expect(copy.timestamp.isAtSameMomentAs(log.timestamp), isTrue);
      expect(copy.latitude, 41.8781);
      expect(copy.longitude, -87.6298);
    });

    test('an unknown context falls back to a standard test', () {
      final copy = BreathLog.fromJson({'timestamp': '2026-10-05T08:30:00Z', 'context': 'from_the_future'});
      expect(copy.context, TestContext.standardBaseline);
      expect(copy.duration, Duration.zero);
    });

    test('withoutLocation removes coordinates only', () {
      final log = makeLog(id: 'x', at: DateTime.utc(2026, 10, 5), seconds: 9, lat: 1, lng: 2);
      expect(log.hasLocation, isTrue);
      final clean = log.withoutLocation();
      expect(clean.hasLocation, isFalse);
      expect(clean.duration, log.duration);
      expect(clean.id, log.id);
    });

    test('enum order is kept, because old data stored indexes', () {
      expect(TestContext.values.indexOf(TestContext.standardBaseline), 0);
      expect(TestContext.values.indexOf(TestContext.postExposure), 1);
      expect(TestContext.values.indexOf(TestContext.relapseSlip), 2);
      expect(TestContext.values.indexOf(TestContext.cravingThreat), 3);
      expect(TestContext.values.indexOf(TestContext.afterSmoking), 4);
    });
  });

  group('AppSettings', () {
    test('privacy-friendly defaults', () {
      const s = AppSettings();
      expect(s.saveCravingLocation, isFalse);
      expect(s.dailyReminderEnabled, isFalse);
      expect(s.milestoneAlertsEnabled, isFalse);
      expect(s.appLockEnabled, isFalse);
    });

    test('JSON round trip', () {
      const s = AppSettings(
        saveCravingLocation: true,
        dailyReminderEnabled: true,
        reminderHour: 7,
        reminderMinute: 45,
        milestoneAlertsEnabled: true,
        appLockEnabled: true,
      );
      final c = AppSettings.fromJson(s.toJson());
      expect(c.saveCravingLocation, isTrue);
      expect(c.reminderHour, 7);
      expect(c.reminderMinute, 45);
      expect(c.milestoneAlertsEnabled, isTrue);
      expect(c.appLockEnabled, isTrue);
    });

    test('out-of-range times are clamped', () {
      final s = AppSettings.fromJson({'reminderHour': 99, 'reminderMinute': -5});
      expect(s.reminderHour, 23);
      expect(s.reminderMinute, 0);
    });

    test('copyWith changes only what is given', () {
      final s = const AppSettings().copyWith(appLockEnabled: true);
      expect(s.appLockEnabled, isTrue);
      expect(s.saveCravingLocation, isFalse);
      expect(s.reminderHour, 20);
    });
  });

  group('UserProfile', () {
    test('JSON round trip', () {
      final p = makeProfile();
      final c = UserProfile.fromJson(p.toJson());
      expect(c.id, p.id);
      expect(c.displayName, 'Alex');
      expect(c.sex, BiologicalSex.female);
      expect(c.heightCm, 170);
      expect(c.cigarettesPerDay, 10);
      expect(c.yearsSmoked, 20);
      expect(c.pricePerPack, 8.5);
      expect(c.quitDate.isAtSameMomentAs(p.quitDate), isTrue);
      expect(c.dateOfBirth.year, 1985);
      expect(c.dateOfBirth.month, 6);
      expect(c.dateOfBirth.day, 15);
    });

    test('pack-years', () {
      expect(makeProfile(cigarettesPerDay: 10, yearsSmoked: 20).packYears, 10.0);
      expect(makeProfile(cigarettesPerDay: null).packYears, isNull);
    });

    test('height in inches', () {
      expect(makeProfile().heightInches, closeTo(66.93, 0.01));
    });

    test('withQuitDate keeps everything else', () {
      final p = makeProfile().withQuitDate(DateTime.utc(2026, 11, 1));
      expect(p.quitDate, DateTime.utc(2026, 11, 1));
      expect(p.displayName, 'Alex');
      expect(p.id, 'p1');
    });
  });
}
