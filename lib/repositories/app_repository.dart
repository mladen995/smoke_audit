// lib/repositories/app_repository.dart
//
// The ONLY place that knows how data is stored. Today: SharedPreferences.
// Later (multiple profiles / lots of logs): swap the internals for Drift/SQLite
// without touching any screen.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/breath_log.dart';
import '../models/user_profile.dart';

class AppRepository {
  static const int schemaVersion = 2;

  // v2 keys
  static const String _kSchema = 'schema_version';
  static const String _kProfiles = 'profiles_v2';
  static const String _kActiveProfile = 'active_profile_id';
  static String _logsKey(String pid) => 'logs_v2_$pid';
  static String _shieldKey(String pid) => 'shield_exp_v2_$pid';
  static String _cooldownKey(String pid) => 'shield_cd_v2_$pid';

  // v1 (legacy) keys
  static const String _legacyLogs = 'biometric_breath_logs';
  static const String _legacyShield = 'shield_expiration_timestamp';
  static const String _legacyCooldown = 'shield_cooldown_timestamp';

  static const String legacyProfileId = 'default';

  // ───────────────────────── Init / migration ─────────────────────────

  /// Call once at startup, before runApp.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final int version = prefs.getInt(_kSchema) ?? 1;
    if (version < 2) {
      try {
        await _migrateV1toV2(prefs);
        await prefs.setInt(_kSchema, 2);
      } catch (e) {
        // Don't crash the app; migration is retried on next launch.
        debugPrint('AppRepository: migration failed: $e');
      }
    }
  }

  Future<void> _migrateV1toV2(SharedPreferences prefs) async {
    final List<String>? legacy = prefs.getStringList(_legacyLogs);

    if (legacy != null) {
      final List<BreathLog> migrated = [];
      for (final str in legacy) {
        try {
          final map = jsonDecode(str) as Map<String, dynamic>;
          final int idx = (map['contextIndex'] as num?)?.toInt() ?? 0;
          final String rawPath = (map['path'] as String?) ?? '';
          migrated.add(BreathLog(
            id: BreathLog.newId(),
            profileId: legacyProfileId,
            kind: LogKind.known.contains(rawPath) ? rawPath : LogKind.acousticTest,
            context: TestContext.values[idx.clamp(0, TestContext.values.length - 1)],
            timestamp: DateTime.parse(map['timestamp'] as String),
            duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
            isManual: (map['isManual'] as bool?) ?? false,
            latitude: (map['latitude'] as num?)?.toDouble(),
            longitude: (map['longitude'] as num?)?.toDouble(),
          ));
        } catch (e) {
          debugPrint('AppRepository: skipped unreadable legacy entry: $e');
        }
      }
      await prefs.setStringList(
        _logsKey(legacyProfileId),
        migrated.map((l) => jsonEncode(l.toJson())).toList(),
      );
    }

    final String? shield = prefs.getString(_legacyShield);
    if (shield != null) await prefs.setString(_shieldKey(legacyProfileId), shield);
    final String? cooldown = prefs.getString(_legacyCooldown);
    if (cooldown != null) await prefs.setString(_cooldownKey(legacyProfileId), cooldown);

    // Only after everything was written successfully:
    await prefs.remove(_legacyLogs);
    await prefs.remove(_legacyShield);
    await prefs.remove(_legacyCooldown);
  }

  // ───────────────────────── Profiles ─────────────────────────

  Future<List<UserProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_kProfiles) ?? [];
    final List<UserProfile> profiles = [];
    for (final s in raw) {
      try {
        profiles.add(UserProfile.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('AppRepository: skipped unreadable profile: $e');
      }
    }
    return profiles;
  }

  Future<UserProfile?> loadActiveProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return null;
    final String? activeId = prefs.getString(_kActiveProfile);
    return profiles.firstWhere((p) => p.id == activeId, orElse: () => profiles.first);
  }

  Future<void> saveProfile(UserProfile profile, {bool makeActive = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await loadProfiles();
    final int idx = profiles.indexWhere((p) => p.id == profile.id);
    if (idx == -1) {
      profiles.add(profile);
    } else {
      profiles[idx] = profile;
    }
    await prefs.setStringList(_kProfiles, profiles.map((p) => jsonEncode(p.toJson())).toList());
    if (makeActive) await prefs.setString(_kActiveProfile, profile.id);
  }

  Future<void> setActiveProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfile, profileId);
  }

  // ───────────────────────── Logs ─────────────────────────

  Future<List<BreathLog>> loadLogs(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_logsKey(profileId)) ?? [];
    final List<BreathLog> logs = [];
    for (final s in raw) {
      try {
        logs.add(BreathLog.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('AppRepository: skipped unreadable log: $e');
      }
    }
    return logs;
  }

  Future<void> saveLogs(String profileId, List<BreathLog> logs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _logsKey(profileId),
      logs.map((l) => jsonEncode(l.toJson())).toList(),
    );
  }

  /// Oldest log time for a profile; used to suggest a quit date for migrated v1 users.
  Future<DateTime?> oldestLogTimestamp(String profileId) async {
    final logs = await loadLogs(profileId);
    if (logs.isEmpty) return null;
    return logs.map((l) => l.timestamp).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  // ───────────────────────── Airway Shield ─────────────────────────

  Future<void> saveShieldExpiration(String profileId, DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_shieldKey(profileId), t.toIso8601String());
  }

  Future<DateTime?> loadShieldExpiration(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_shieldKey(profileId));
    return s == null ? null : DateTime.tryParse(s);
  }

  Future<void> clearShieldExpiration(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_shieldKey(profileId));
  }

  Future<void> saveShieldCooldown(String profileId, DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cooldownKey(profileId), t.toIso8601String());
  }

  Future<DateTime?> loadShieldCooldown(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_cooldownKey(profileId));
    return s == null ? null : DateTime.tryParse(s);
  }

  Future<void> clearShieldCooldown(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cooldownKey(profileId));
  }

  // ───────────────────────── Maintenance ─────────────────────────

  /// Wipes logs + shield state for one profile (keeps the profile itself).
  Future<void> resetProfileData(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logsKey(profileId));
    await prefs.remove(_shieldKey(profileId));
    await prefs.remove(_cooldownKey(profileId));
  }
}