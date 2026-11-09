// lib/services/reminder_service.dart
//
// Local notifications: an optional daily check-in and optional milestone alerts.
// Uses INEXACT alarms, so no special "exact alarm" permission is needed.
// Everything is wrapped in try/catch: a notification problem must never crash the app.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_settings.dart';
import '../models/medical_milestone_model.dart';

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const int _dailyId = 1;
  static const int _milestoneBaseId = 100;
  static const String _title = 'AirEngine';

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'airengine_reminders',
      'Reminders',
      channelDescription: 'Daily check-in and milestone reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
    iOS: DarwinNotificationDetails(),
  );

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();
      try {
        // Older versions return a String, newer ones an object with `identifier`.
        final dynamic info = await FlutterTimezone.getLocalTimezone();
        final String name = info is String ? info : (info.identifier as String);
        tz.setLocalLocation(tz.getLocation(name));
      } catch (e) {
        debugPrint('ReminderService: could not read the device time zone ($e); using UTC.');
      }

      const AndroidInitializationSettings android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(const InitializationSettings(android: android, iOS: darwin));
      _initialized = true;
    } catch (e) {
      debugPrint('ReminderService: init failed: $e');
    }
  }

  /// Asks the OS for notification permission. Returns true when allowed.
  Future<bool> requestPermission() async {
    await init();
    if (!_initialized) return false;
    try {
      final AndroidFlutterLocalNotificationsPlugin? android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return (await android.requestNotificationsPermission()) ?? false;
      }
      final IOSFlutterLocalNotificationsPlugin? ios =
          _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return (await ios.requestPermissions(alert: true, badge: false, sound: true)) ?? false;
      }
      return true;
    } catch (e) {
      debugPrint('ReminderService: permission request failed: $e');
      return false;
    }
  }

  /// Makes the scheduled notifications match [settings]. Call it on every app
  /// start (so a changed time zone is picked up) and whenever the streak or settings change.
  Future<void> sync(AppSettings settings, DateTime? streakStart) async {
    await init();
    if (!_initialized) return;
    try {
      if (settings.dailyReminderEnabled) {
        await _scheduleDaily(settings.reminderHour, settings.reminderMinute);
      } else {
        await _plugin.cancel(_dailyId);
      }

      await _cancelMilestones();
      if (settings.milestoneAlertsEnabled && streakStart != null) {
        await _scheduleMilestones(streakStart);
      }
    } catch (e) {
      debugPrint('ReminderService: sync failed: $e');
    }
  }

  Future<void> cancelAll() async {
    await init();
    if (!_initialized) return;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('ReminderService: cancelAll failed: $e');
    }
  }

  Future<void> _scheduleDaily(int hour, int minute) async {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime next = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) {
      next = tz.TZDateTime(tz.local, now.year, now.month, now.day + 1, hour, minute);
    }
    await _plugin.zonedSchedule(
      _dailyId,
      _title,
      'Time for your daily breath check-in.',
      next,
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> _scheduleMilestones(DateTime streakStart) async {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    final tz.TZDateTime horizon = now.add(const Duration(days: 400));
    final List<MedicalMilestone> all = MedicalMilestonesData.milestones;
    for (int i = 0; i < all.length; i++) {
      final tz.TZDateTime when = tz.TZDateTime.from(streakStart.add(all[i].targetDuration), tz.local);
      if (!when.isAfter(now.add(const Duration(minutes: 1)))) continue; // already reached
      if (when.isAfter(horizon)) continue; // rescheduled on later launches
      await _plugin.zonedSchedule(
        _milestoneBaseId + i,
        _title,
        'You reached a new health milestone. Open the app to see it.',
        when,
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  Future<void> _cancelMilestones() async {
    for (int i = 0; i < MedicalMilestonesData.milestones.length; i++) {
      await _plugin.cancel(_milestoneBaseId + i);
    }
  }
}
