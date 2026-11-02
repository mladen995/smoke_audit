// lib/models/breath_log.dart
import 'dart:math';

/// ORDER MATTERS for migrating v1 data (v1 stored the enum index).
enum TestContext {
  standardBaseline,
  postExposure, // Secondhand / passive exposure
  relapseSlip, // Active slip-ups / relapses
  cravingThreat, // Active Shield / craving tracking
  // APPENDED (v1 data stored enum indexes 0-3, so new values must go at the end):
  afterSmoking, // Test taken right after smoking (counts as a slip-up)
}

/// What produced a log entry (replaces the old magic 'path' strings).
abstract class LogKind {
  static const String acousticTest = 'ACOUSTIC_TEST';
  static const String cravingMarker = 'CRAVING_TRIGGER_MARKER';
  static const String userSlip = 'USER_DECLARED_SLIP_UP';
  static const String backdatedRelapse = 'RETROACTIVE_BACKDATED_LOG';
  static const String trackingStart = 'FIRST_LAUNCH_BASELINE'; // legacy v1 entries only
  static const String baselineSession = 'BASELINE_SESSION'; // part of the guided 3-test baseline

  static const Set<String> known = {
    baselineSession,
    acousticTest,
    cravingMarker,
    userSlip,
    backdatedRelapse,
    trackingStart,
  };
}

class BreathLog {
  final String id;
  final String profileId;
  final String kind;
  final TestContext context;
  final DateTime timestamp;
  final Duration duration;
  final bool isManual;
  final double? latitude;
  final double? longitude;

  const BreathLog({
    required this.id,
    required this.profileId,
    required this.kind,
    required this.context,
    required this.timestamp,
    required this.duration,
    required this.isManual,
    this.latitude,
    this.longitude,
  });

  factory BreathLog.create({
    required String profileId,
    required String kind,
    required TestContext context,
    required DateTime timestamp,
    Duration duration = Duration.zero,
    bool isManual = false,
    double? latitude,
    double? longitude,
  }) {
    return BreathLog(
      id: newId(),
      profileId: profileId,
      kind: kind,
      context: context,
      timestamp: timestamp,
      duration: duration,
      isManual: isManual,
      latitude: latitude,
      longitude: longitude,
    );
  }

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'profileId': profileId,
        'kind': kind,
        'context': context.name,
        'timestamp': timestamp.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'isManual': isManual,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory BreathLog.fromJson(Map<String, dynamic> json) {
    return BreathLog(
      id: (json['id'] as String?) ?? newId(),
      profileId: (json['profileId'] as String?) ?? 'default',
      kind: (json['kind'] as String?) ?? LogKind.acousticTest,
      context: TestContext.values.firstWhere(
        (e) => e.name == json['context'],
        orElse: () => TestContext.standardBaseline,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      isManual: (json['isManual'] as bool?) ?? false,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }
}