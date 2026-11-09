import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smoke_audit/models/app_settings.dart';
import 'package:smoke_audit/models/breath_log.dart';
import 'package:smoke_audit/repositories/app_repository.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppRepository> freshRepo([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final repo = AppRepository();
    await repo.init();
    return repo;
  }

  test('a fresh install has no profile and default settings', () async {
    final repo = await freshRepo();
    expect(await repo.loadProfiles(), isEmpty);
    expect(await repo.loadActiveProfile(), isNull);
    final AppSettings s = await repo.loadSettings();
    expect(s.saveCravingLocation, isFalse);
  });

  test('v1 data is migrated, bad entries are skipped, old keys are removed', () async {
    final repo = await freshRepo({
      'biometric_breath_logs': <String>[
        jsonEncode({
          'contextIndex': 4,
          'path': 'ACOUSTIC_TEST',
          'timestamp': '2026-10-01T12:00:00.000',
          'durationMs': 8000,
          'isManual': false,
        }),
        'this is not json',
      ],
      'shield_expiration_timestamp': '2026-10-01T12:10:00.000',
    });

    final logs = await repo.loadLogs(AppRepository.legacyProfileId);
    expect(logs.length, 1);
    expect(logs.first.context, TestContext.afterSmoking);
    expect(logs.first.duration, const Duration(seconds: 8));
    expect(await repo.loadShieldExpiration(AppRepository.legacyProfileId), isNotNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('biometric_breath_logs'), isFalse);
    expect(prefs.containsKey('shield_expiration_timestamp'), isFalse);
  });

  test('settings round trip, and corrupt settings fall back to defaults', () async {
    final repo = await freshRepo();
    await repo.saveSettings(const AppSettings(appLockEnabled: true, reminderHour: 6));
    final s = await repo.loadSettings();
    expect(s.appLockEnabled, isTrue);
    expect(s.reminderHour, 6);

    final broken = await freshRepo({'app_settings_v1': '{{{'});
    expect((await broken.loadSettings()).appLockEnabled, isFalse);
  });

  test('profiles: save, list, switch active', () async {
    final repo = await freshRepo();
    await repo.saveProfile(makeProfile(id: 'a'));
    await repo.saveProfile(makeProfile(id: 'b', name: 'Sam'));
    expect((await repo.loadProfiles()).map((p) => p.id).toSet(), {'a', 'b'});
    expect((await repo.loadActiveProfile())!.id, 'b'); // newest save becomes active
    await repo.setActiveProfile('a');
    expect((await repo.loadActiveProfile())!.id, 'a');
  });

  test('logs round trip and unreadable entries are skipped', () async {
    final repo = await freshRepo({
      'logs_v2_p1': <String>[
        jsonEncode(makeLog(id: 'ok', at: DateTime.utc(2026, 10, 1), seconds: 9).toJson()),
        'garbage',
      ],
    });
    final logs = await repo.loadLogs('p1');
    expect(logs.length, 1);
    expect(logs.first.id, 'ok');

    await repo.saveLogs('p1', [makeLog(id: 'n', at: DateTime.utc(2026, 10, 2), seconds: 7)]);
    expect((await repo.loadLogs('p1')).single.id, 'n');
  });

  test('deleteAllLocations clears coordinates and reports how many', () async {
    final repo = await freshRepo();
    await repo.saveProfile(makeProfile(id: 'p1'));
    await repo.saveLogs('p1', [
      makeLog(id: '1', at: DateTime.utc(2026, 10, 1), lat: 1, lng: 2),
      makeLog(id: '2', at: DateTime.utc(2026, 10, 2), seconds: 9, lat: 3, lng: 4),
      makeLog(id: '3', at: DateTime.utc(2026, 10, 3), seconds: 9),
    ]);
    expect(await repo.deleteAllLocations(), 2);
    final logs = await repo.loadLogs('p1');
    expect(logs.length, 3);
    expect(logs.any((l) => l.hasLocation), isFalse);
    expect(await repo.deleteAllLocations(), 0);
  });

  test('shield timers round trip and clear', () async {
    final repo = await freshRepo();
    final t = DateTime.utc(2026, 10, 1, 12, 0, 0);
    await repo.saveShieldExpiration('p1', t);
    await repo.saveShieldCooldown('p1', t);
    expect((await repo.loadShieldExpiration('p1'))!.isAtSameMomentAs(t), isTrue);
    expect((await repo.loadShieldCooldown('p1'))!.isAtSameMomentAs(t), isTrue);
    await repo.clearShieldExpiration('p1');
    await repo.clearShieldCooldown('p1');
    expect(await repo.loadShieldExpiration('p1'), isNull);
    expect(await repo.loadShieldCooldown('p1'), isNull);
  });

  test('resetProfileData wipes logs and timers for that profile only', () async {
    final repo = await freshRepo();
    await repo.saveLogs('p1', [makeLog(id: '1', at: DateTime.utc(2026, 10, 1), seconds: 5)]);
    await repo.saveLogs('p2', [makeLog(id: '2', at: DateTime.utc(2026, 10, 1), seconds: 5, profileId: 'p2')]);
    await repo.saveShieldExpiration('p1', DateTime.utc(2026, 10, 1));
    await repo.resetProfileData('p1');
    expect(await repo.loadLogs('p1'), isEmpty);
    expect(await repo.loadShieldExpiration('p1'), isNull);
    expect((await repo.loadLogs('p2')).length, 1);
  });

  test('replaceAllData swaps everything and picks a valid active profile', () async {
    final repo = await freshRepo();
    await repo.saveProfile(makeProfile(id: 'old'));
    await repo.saveLogs('old', [makeLog(id: '1', at: DateTime.utc(2026, 10, 1), seconds: 5, profileId: 'old')]);

    await repo.replaceAllData(
      profiles: [makeProfile(id: 'new', name: 'Sam')],
      logsByProfile: {'new': [makeLog(id: '9', at: DateTime.utc(2026, 10, 5), seconds: 6, profileId: 'new')]},
      activeProfileId: 'old', // no longer exists
    );

    expect((await repo.loadProfiles()).map((p) => p.id).toList(), ['new']);
    expect(await repo.loadLogs('old'), isEmpty);
    expect((await repo.loadLogs('new')).single.id, '9');
    expect((await repo.loadActiveProfile())!.id, 'new');
  });
}
