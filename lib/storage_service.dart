// lib/storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _dbKey = 'biometric_breath_logs';

  static Future<void> persistLogs(List<Map<String, dynamic>> logs) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> serializedStrings = logs.map((log) {
      return jsonEncode({
        'path': log['path'],
        'durationMs': (log['duration'] as Duration).inMilliseconds,
        'contextIndex': log['context'] == null ? 0 : (log['context'] as Enum).index,
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
        'context': map['contextIndex'] == 1 ? "TestContext.postExposure" : "TestContext.standardBaseline",
        'timestamp': DateTime.parse(map['timestamp']),
        'isManual': map['isManual'] ?? false,
      };
    }).toList();
  }
}