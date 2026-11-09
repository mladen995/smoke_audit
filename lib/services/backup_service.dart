// lib/services/backup_service.dart
//
// JSON backup / restore. encode / parse / mergeLogs / planRestore are pure
// (unit-tested); the file picking and repository writes are thin wrappers.
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/breath_log.dart';
import '../models/user_profile.dart';
import '../repositories/app_repository.dart';
import '../utils/time_codec.dart';
import 'export_service.dart';

enum RestoreMode { merge, replace }

class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

class ParsedBackup {
  final DateTime? exportedAt;
  final List<UserProfile> profiles;
  final Map<String, List<BreathLog>> logsByProfile;
  final int skippedEntries;

  const ParsedBackup({
    required this.exportedAt,
    required this.profiles,
    required this.logsByProfile,
    required this.skippedEntries,
  });

  int get totalLogs => logsByProfile.values.fold(0, (sum, l) => sum + l.length);
}

class RestorePlan {
  final List<UserProfile> profiles;
  final Map<String, List<BreathLog>> logsByProfile;
  final int addedLogs;
  final int addedProfiles;

  const RestorePlan({
    required this.profiles,
    required this.logsByProfile,
    required this.addedLogs,
    required this.addedProfiles,
  });
}

class BackupService {
  BackupService(this.repo);

  final AppRepository repo;

  static const String formatId = 'airengine-backup';
  static const int formatVersion = 1;
  static const int maxBytes = 10 * 1024 * 1024;
  static const Duration maxExhale = Duration(minutes: 10);

  // ───────────────────────── pure functions ─────────────────────────

  static String encode({
    required List<UserProfile> profiles,
    required Map<String, List<BreathLog>> logsByProfile,
    required DateTime now,
  }) {
    final Map<String, dynamic> map = {
      'format': formatId,
      'formatVersion': formatVersion,
      'exportedAt': TimeCodec.encode(now),
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'logs': {
        for (final p in profiles)
          p.id: (logsByProfile[p.id] ?? const <BreathLog>[]).map((l) => l.toJson()).toList(),
      },
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// Validates and parses a backup. Throws [BackupFormatException] with a
  /// message that is safe to show to the user. Unreadable entries are skipped
  /// and counted instead of failing the whole restore.
  static ParsedBackup parse(String source) {
    dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupFormatException('This file is not a valid AirEngine backup.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('This file is not a valid AirEngine backup.');
    }
    if (decoded['format'] != formatId) {
      throw const BackupFormatException('This is not an AirEngine backup file.');
    }
    final dynamic version = decoded['formatVersion'];
    if (version is! int || version < 1) {
      throw const BackupFormatException('This file is not a valid AirEngine backup.');
    }
    if (version > formatVersion) {
      throw const BackupFormatException(
          'This backup was made by a newer version of the app. Please update the app first.');
    }

    final dynamic rawProfiles = decoded['profiles'];
    if (rawProfiles is! List || rawProfiles.isEmpty) {
      throw const BackupFormatException('This backup does not contain a profile.');
    }

    int skipped = 0;
    final List<UserProfile> profiles = [];
    final Set<String> seenProfileIds = {};
    for (final dynamic p in rawProfiles) {
      try {
        final UserProfile profile = UserProfile.fromJson(p as Map<String, dynamic>);
        if (seenProfileIds.add(profile.id)) profiles.add(profile);
      } catch (_) {
        skipped++;
      }
    }
    if (profiles.isEmpty) {
      throw const BackupFormatException('This backup does not contain a readable profile.');
    }

    final Map<String, List<BreathLog>> logsByProfile = {
      for (final p in profiles) p.id: <BreathLog>[],
    };
    final dynamic rawLogs = decoded['logs'];
    if (rawLogs is Map) {
      rawLogs.forEach((dynamic key, dynamic value) {
        final String pid = key.toString();
        final List<BreathLog>? bucket = logsByProfile[pid];
        if (bucket == null || value is! List) return;
        final Set<String> ids = {};
        for (final dynamic item in value) {
          try {
            final BreathLog log = BreathLog.fromJson(item as Map<String, dynamic>);
            if (log.duration.isNegative || log.duration > maxExhale) {
              skipped++;
              continue;
            }
            if (!ids.add(log.id)) continue; // duplicate inside the file
            bucket.add(log.withProfileId(pid));
          } catch (_) {
            skipped++;
          }
        }
      });
    }

    final dynamic exportedRaw = decoded['exportedAt'];
    return ParsedBackup(
      exportedAt: exportedRaw is String ? TimeCodec.tryDecode(exportedRaw) : null,
      profiles: profiles,
      logsByProfile: logsByProfile,
      skippedEntries: skipped,
    );
  }

  /// Union by entry id (local copy wins), newest first.
  static List<BreathLog> mergeLogs(List<BreathLog> local, List<BreathLog> incoming) {
    final Map<String, BreathLog> byId = {for (final l in local) l.id: l};
    for (final l in incoming) {
      byId.putIfAbsent(l.id, () => l);
    }
    final List<BreathLog> merged = byId.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return merged;
  }

  static RestorePlan planRestore({
    required RestoreMode mode,
    required List<UserProfile> localProfiles,
    required Map<String, List<BreathLog>> localLogs,
    required ParsedBackup backup,
  }) {
    if (mode == RestoreMode.replace) {
      return RestorePlan(
        profiles: List<UserProfile>.of(backup.profiles),
        logsByProfile: {
          for (final p in backup.profiles)
            p.id: List<BreathLog>.of(backup.logsByProfile[p.id] ?? const <BreathLog>[]),
        },
        addedLogs: backup.totalLogs,
        addedProfiles: backup.profiles.length,
      );
    }

    final List<UserProfile> profiles = [...localProfiles];
    final Set<String> localIds = localProfiles.map((p) => p.id).toSet();
    int addedProfiles = 0;
    for (final p in backup.profiles) {
      if (!localIds.contains(p.id)) {
        profiles.add(p);
        addedProfiles++;
      }
    }

    final Map<String, List<BreathLog>> logs = {};
    int added = 0;
    for (final p in profiles) {
      final List<BreathLog> local = localLogs[p.id] ?? const <BreathLog>[];
      final List<BreathLog> merged = mergeLogs(local, backup.logsByProfile[p.id] ?? const <BreathLog>[]);
      added += merged.length - local.length;
      logs[p.id] = merged;
    }
    return RestorePlan(
      profiles: profiles,
      logsByProfile: logs,
      addedLogs: added,
      addedProfiles: addedProfiles,
    );
  }

  // ───────────────────────── device-facing wrappers ─────────────────────────

  /// Writes a full backup into a temp file and returns its path (share it, then delete it).
  Future<String> createBackupFile(DateTime now) async {
    final List<UserProfile> profiles = await repo.loadProfiles();
    final Map<String, List<BreathLog>> logs = {};
    for (final p in profiles) {
      logs[p.id] = await repo.loadLogs(p.id);
    }
    final String text = encode(profiles: profiles, logsByProfile: logs, now: now);
    return ExportService.writeTempString('${ExportService.filePrefix}Backup_${ExportService.stamp(now)}.json', text);
  }

  /// Lets the user choose a file. Returns null if they cancel.
  Future<ParsedBackup?> pickAndParse() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final PlatformFile file = result.files.first;
    List<int>? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      throw const BackupFormatException('Could not read the selected file.');
    }
    if (bytes.length > maxBytes) {
      throw const BackupFormatException('That file is too large to be an AirEngine backup.');
    }

    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const BackupFormatException('This file is not a valid AirEngine backup.');
    }
    return parse(text);
  }

  Future<RestorePlan> restore(ParsedBackup backup, RestoreMode mode) async {
    final List<UserProfile> localProfiles = await repo.loadProfiles();
    final Map<String, List<BreathLog>> localLogs = {};
    for (final p in localProfiles) {
      localLogs[p.id] = await repo.loadLogs(p.id);
    }
    final UserProfile? active = await repo.loadActiveProfile();

    final RestorePlan plan = planRestore(
      mode: mode,
      localProfiles: localProfiles,
      localLogs: localLogs,
      backup: backup,
    );
    await repo.replaceAllData(
      profiles: plan.profiles,
      logsByProfile: plan.logsByProfile,
      activeProfileId: active?.id,
    );
    return plan;
  }
}
