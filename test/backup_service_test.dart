import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoke_audit/models/user_profile.dart';
import 'package:smoke_audit/services/backup_service.dart';

import 'test_helpers.dart';

String _backup({List<dynamic>? extraLogs, Map<String, dynamic>? overrides}) {
  final p = makeProfile();
  final logs = [
    makeLog(id: 'a', at: DateTime.utc(2026, 10, 2), seconds: 10),
    makeLog(id: 'b', at: DateTime.utc(2026, 10, 3), seconds: 11, lat: 1.5, lng: 2.5),
  ];
  final map = jsonDecode(BackupService.encode(
    profiles: [p],
    logsByProfile: {'p1': logs},
    now: DateTime.utc(2026, 11, 1, 12),
  )) as Map<String, dynamic>;
  if (extraLogs != null) (map['logs']['p1'] as List).addAll(extraLogs);
  if (overrides != null) map.addAll(overrides);
  return jsonEncode(map);
}

void main() {
  group('parse', () {
    test('round trip keeps profiles, logs and the export time', () {
      final ParsedBackup b = BackupService.parse(_backup());
      expect(b.profiles.length, 1);
      expect(b.profiles.first.displayName, 'Alex');
      expect(b.logsByProfile['p1']!.length, 2);
      expect(b.totalLogs, 2);
      expect(b.skippedEntries, 0);
      expect(b.exportedAt!.isAtSameMomentAs(DateTime.utc(2026, 11, 1, 12)), isTrue);
      expect(b.logsByProfile['p1']!.last.latitude, 1.5);
    });

    test('rejects text that is not JSON', () {
      expect(() => BackupService.parse('hello'), throwsA(isA<BackupFormatException>()));
    });

    test('rejects JSON that is not an object', () {
      expect(() => BackupService.parse('[1,2,3]'), throwsA(isA<BackupFormatException>()));
    });

    test('rejects another app\'s JSON', () {
      expect(() => BackupService.parse('{"format":"something-else","formatVersion":1}'),
          throwsA(isA<BackupFormatException>()));
    });

    test('rejects a newer format version with a helpful message', () {
      expect(
        () => BackupService.parse(_backup(overrides: {'formatVersion': 99})),
        throwsA(isA<BackupFormatException>().having((e) => e.message, 'message', contains('newer'))),
      );
    });

    test('rejects a backup without profiles', () {
      expect(() => BackupService.parse(_backup(overrides: {'profiles': []})),
          throwsA(isA<BackupFormatException>()));
    });

    test('skips corrupt and absurd entries but keeps the rest', () {
      final ParsedBackup b = BackupService.parse(_backup(extraLogs: [
        {'foo': 'bar'}, // unreadable
        {'id': 'huge', 'timestamp': '2026-10-04T00:00:00Z', 'durationMs': 11 * 60 * 1000}, // > 10 min
        {'id': 'neg', 'timestamp': '2026-10-04T00:00:00Z', 'durationMs': -5},
      ]));
      expect(b.logsByProfile['p1']!.length, 2);
      expect(b.skippedEntries, 3);
    });

    test('duplicate ids inside the file are dropped', () {
      final ParsedBackup b = BackupService.parse(_backup(extraLogs: [
        {'id': 'a', 'timestamp': '2026-10-02T00:00:00Z', 'durationMs': 9000},
      ]));
      expect(b.logsByProfile['p1']!.length, 2);
    });
  });

  group('merge and restore planning', () {
    final p1 = makeProfile(id: 'p1');
    final p2 = makeProfile(id: 'p2', name: 'Sam');
    final a = makeLog(id: 'a', at: DateTime.utc(2026, 10, 2), seconds: 10);
    final aEdited = makeLog(id: 'a', at: DateTime.utc(2026, 10, 2), seconds: 99);
    final b = makeLog(id: 'b', at: DateTime.utc(2026, 10, 3), seconds: 11);
    final c = makeLog(id: 'c', at: DateTime.utc(2026, 10, 4), profileId: 'p2', seconds: 12);

    test('mergeLogs keeps the local copy and sorts newest first', () {
      final merged = BackupService.mergeLogs([a], [aEdited, b]);
      expect(merged.map((l) => l.id).toList(), ['b', 'a']);
      expect(merged.last.duration, const Duration(seconds: 10));
    });

    final backup = ParsedBackup(
      exportedAt: null,
      profiles: [p1, p2],
      logsByProfile: {'p1': [a, b], 'p2': [c]},
      skippedEntries: 0,
    );

    test('merge adds only what is missing', () {
      final RestorePlan plan = BackupService.planRestore(
        mode: RestoreMode.merge,
        localProfiles: [p1],
        localLogs: {'p1': [a]},
        backup: backup,
      );
      expect(plan.profiles.map((p) => p.id).toList(), ['p1', 'p2']);
      expect(plan.addedProfiles, 1);
      expect(plan.addedLogs, 2); // b and c
      expect(plan.logsByProfile['p1']!.length, 2);
      expect(plan.logsByProfile['p2']!.length, 1);
    });

    test('merge into an empty phone adds everything', () {
      final RestorePlan plan = BackupService.planRestore(
        mode: RestoreMode.merge,
        localProfiles: const <UserProfile>[],
        localLogs: const {},
        backup: backup,
      );
      expect(plan.addedProfiles, 2);
      expect(plan.addedLogs, 3);
    });

    test('replace uses the backup as it is', () {
      final RestorePlan plan = BackupService.planRestore(
        mode: RestoreMode.replace,
        localProfiles: [p1],
        localLogs: {'p1': [aEdited]},
        backup: backup,
      );
      expect(plan.profiles.length, 2);
      expect(plan.addedLogs, 3);
      expect(plan.logsByProfile['p1']!.firstWhere((l) => l.id == 'a').duration, const Duration(seconds: 10));
    });
  });
}
