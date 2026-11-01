// lib/storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _dbKey = 'biometric_breath_logs';

  static Future<void> persistLogs(List<Map<String, dynamic>> logs) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> serializedStrings = logs.map((log) {
      // Safely handle enum index extraction
      int contextIdx = 0;
      final ctx = log['context'];
      if (ctx is Enum) {
        contextIdx = ctx.index;
      } else if (ctx is int) {
        contextIdx = ctx;
      }

      return jsonEncode({
        'path': log['path'],
        'durationMs': (log['duration'] as Duration).inMilliseconds,
        'contextIndex': contextIdx,
        'timestamp': (log['timestamp'] as DateTime).toIso8601String(),
        'isManual': log['isManual'] ?? false,
      });
    }).toList();
    await prefs.setStringList(_dbKey, serializedStrings);
  }

  static Future<List<Map<String, dynamic>>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? serializedStrings = prefs.getStringList(_dbKey);
    if (serializedStrings == null) return [];

    return serializedStrings.map((str) {
      final map = jsonDecode(str);
      
      return {
        'path': map['path'],
        'duration': Duration(milliseconds: map['durationMs']),
        'contextIndex': map['contextIndex'] ?? 0, // 👈 Return raw index to be parsed in screen
        'timestamp': DateTime.parse(map['timestamp']),
        'isManual': map['isManual'] ?? false,
      };
    }).toList();
  }

  static const String _shieldKey = 'shield_expiration_timestamp';

  static Future<void> saveShieldExpiration(DateTime expirationTime) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_shieldKey, expirationTime.toIso8601String());
  }

  static Future<DateTime?> loadShieldExpiration() async {
    final prefs = await SharedPreferences.getInstance();
    final String? timeStr = prefs.getString(_shieldKey);
    if (timeStr == null) return null;
    return DateTime.tryParse(timeStr);
  }

  static Future<void> clearShieldExpiration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_shieldKey);
  }

  static const String _cooldownKey = 'shield_cooldown_timestamp';

  static Future<void> saveShieldCooldown(DateTime endTime) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cooldownKey, endTime.toIso8601String());
  }

  static Future<DateTime?> loadShieldCooldown() async {
    final prefs = await SharedPreferences.getInstance();
    final String? timeStr = prefs.getString(_cooldownKey);
    if (timeStr == null) return null;
    return DateTime.tryParse(timeStr);
  }

  static Future<void> clearShieldCooldown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cooldownKey);
  }
}