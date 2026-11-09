// lib/models/app_settings.dart

class AppSettings {
  /// Off by default: location is only stored when the user opts in.
  final bool saveCravingLocation;

  final bool dailyReminderEnabled;
  final int reminderHour;
  final int reminderMinute;
  final bool milestoneAlertsEnabled;

  final bool appLockEnabled;

  const AppSettings({
    this.saveCravingLocation = false,
    this.dailyReminderEnabled = false,
    this.reminderHour = 20,
    this.reminderMinute = 0,
    this.milestoneAlertsEnabled = false,
    this.appLockEnabled = false,
  });

  AppSettings copyWith({
    bool? saveCravingLocation,
    bool? dailyReminderEnabled,
    int? reminderHour,
    int? reminderMinute,
    bool? milestoneAlertsEnabled,
    bool? appLockEnabled,
  }) {
    return AppSettings(
      saveCravingLocation: saveCravingLocation ?? this.saveCravingLocation,
      dailyReminderEnabled: dailyReminderEnabled ?? this.dailyReminderEnabled,
      reminderHour: reminderHour ?? this.reminderHour,
      reminderMinute: reminderMinute ?? this.reminderMinute,
      milestoneAlertsEnabled: milestoneAlertsEnabled ?? this.milestoneAlertsEnabled,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'saveCravingLocation': saveCravingLocation,
        'dailyReminderEnabled': dailyReminderEnabled,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
        'milestoneAlertsEnabled': milestoneAlertsEnabled,
        'appLockEnabled': appLockEnabled,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    int clampInt(Object? v, int fallback, int min, int max) {
      final int n = (v is num) ? v.toInt() : fallback;
      return n < min ? min : (n > max ? max : n);
    }

    return AppSettings(
      saveCravingLocation: (json['saveCravingLocation'] as bool?) ?? false,
      dailyReminderEnabled: (json['dailyReminderEnabled'] as bool?) ?? false,
      reminderHour: clampInt(json['reminderHour'], 20, 0, 23),
      reminderMinute: clampInt(json['reminderMinute'], 0, 0, 59),
      milestoneAlertsEnabled: (json['milestoneAlertsEnabled'] as bool?) ?? false,
      appLockEnabled: (json['appLockEnabled'] as bool?) ?? false,
    );
  }
}
