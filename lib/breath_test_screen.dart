import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:geolocator/geolocator.dart';

import 'app_controller.dart';
import 'breath_audio_service.dart';
import 'logic/tracker_logic.dart';
import 'models/app_settings.dart';
import 'models/breath_log.dart';
import 'models/user_profile.dart';
import 'onboarding_screen.dart';
import 'repositories/app_repository.dart';
import 'services/reminder_service.dart';
import 'settings_screen.dart';
import 'utils/formatters.dart';
import 'widgets/export_sheet.dart';
import 'widgets/milestone_progress_card.dart';

class _SessionResult {
  final Duration duration;
  final DateTime timestamp;
  const _SessionResult(this.duration, this.timestamp);
}

class BreathTestScreen extends StatefulWidget {
  final AppRepository repo;
  final AppController controller;
  final UserProfile profile;

  /// Called when the profile is edited or reset, so the app root keeps the same copy.
  final void Function(UserProfile profile) onProfileChanged;

  /// Called after a backup restore replaced the stored data; the root reloads everything.
  final Future<void> Function() onDataReplaced;

  const BreathTestScreen({
    super.key,
    required this.repo,
    required this.controller,
    required this.profile,
    required this.onProfileChanged,
    required this.onDataReplaced,
  });

  @override
  State<BreathTestScreen> createState() => _BreathTestScreenState();
}

class _BreathTestScreenState extends State<BreathTestScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late BreathAudioService _audioService;
  late TabController _timeframeTabController;
  late UserProfile _profile;

  String get _pid => _profile.id;

  BreathRecorderState _currentStatus = BreathRecorderState.idle;
  double _liveVolumeLevel = 0.0;
  StreamSubscription<double>? _volumeSubscription;

  final List<BreathLog> _historicalLogs = [];
  Timer? _tickerTimer;

  int _cravingSecondsLeft = 0;
  bool _isCravingModeActive = false;
  DateTime? _shieldExpiration;
  bool _shieldCompleting = false;
  bool _isStartingShield = false;
  bool _isStartingTest = false;

  // Guided personal-baseline session
  bool _baselineSessionActive = false;
  final List<_SessionResult> _sessionResults = [];

  // 15-minute clinical buffer window after a shield ends
  DateTime? _lastShieldEndTime;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
    WidgetsBinding.instance.addObserver(this);
    _timeframeTabController = TabController(length: 4, vsync: this);

    _timeframeTabController.addListener(() {
      if (!_timeframeTabController.indexIsChanging) {
        setState(() {});
      }
    });

    _audioService = BreathAudioService(
      onStateChanged: _handleStateTransitions,
      onRecordingComplete: (result) {
        if (!mounted) return;
        if (_baselineSessionActive) {
          _handleBaselineSessionResult(result);
        } else {
          _showValidationDialog(context, result);
        }
      },
      onTestInvalid: (reason) => _showSnack(reason, color: Colors.orange.shade800),
    );

    _volumeSubscription = _audioService.volumeStream.listen((normalizedDb) {
      if (mounted) {
        setState(() {
          _liveVolumeLevel = normalizedDb;
        });
      }
    });

    _resetGlobalTimelineTicker();
    _loadPersistedDatabase();
    _checkRestoredShieldTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _volumeSubscription?.cancel();
    _tickerTimer?.cancel();
    _timeframeTabController.dispose();
    _audioService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkRestoredShieldTimer();
    }
  }

  void _showSnack(String message, {Color? color, Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: duration ?? const Duration(seconds: 4),
      ));
  }

  // ───────────────────────── Profile ─────────────────────────

  Future<void> _editProfile() async {
    if (!mounted) return;
    final UserProfile? updated = await Navigator.of(context).push<UserProfile>(
      MaterialPageRoute(
        builder: (ctx) => OnboardingScreen(
          initialProfile: _profile,
          onComplete: (p) => Navigator.of(ctx).pop(p),
        ),
      ),
    );
    if (updated == null || !mounted) return;

    // Quit date drives the streak and every milestone, so confirm before rewriting it.
    final bool quitDateChanged =
        updated.quitDate.difference(_profile.quitDate).abs() > const Duration(minutes: 1);
    if (quitDateChanged) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text("Change quit date?"),
          content: const Text(
            "This rewrites your smoke-free streak and milestone progress. "
            "Slip-ups you logged after the new date will still count.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("Cancel")),
            ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text("Change")),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    await widget.repo.saveProfile(updated);
    if (!mounted) return;
    setState(() => _profile = updated);
    widget.onProfileChanged(updated);
    _syncReminders();
    _showSnack("Profile updated.", color: Colors.blueGrey);
  }

  // ───────────────────────── Shield timer ─────────────────────────

  Future<void> _checkRestoredShieldTimer() async {
    final DateTime? expirationTime = await widget.repo.loadShieldExpiration(_pid);
    if (expirationTime == null || !mounted) return;

    final int remainingSeconds =
        (expirationTime.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    if (remainingSeconds > 0) {
      setState(() {
        _shieldExpiration = expirationTime;
        _isCravingModeActive = true;
        _cravingSecondsLeft = remainingSeconds;
      });
    } else {
      await _completeShield();
    }
  }

  Future<void> _completeShield() async {
    if (_shieldCompleting) return;
    _shieldCompleting = true;
    final DateTime end = DateTime.now();

    if (mounted) {
      setState(() {
        _isCravingModeActive = false;
        _cravingSecondsLeft = 0;
        _shieldExpiration = null;
        _lastShieldEndTime = end;
      });
    }
    await widget.repo.saveShieldCooldown(_pid, end);
    await widget.repo.clearShieldExpiration(_pid);
    _shieldCompleting = false;

    if (mounted) _showCravingCompleteAlert();
  }

  void _resetGlobalTimelineTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;

      bool shieldFinished = false;
      setState(() {
        if (_isCravingModeActive && _shieldExpiration != null) {
          final ms = _shieldExpiration!.difference(DateTime.now()).inMilliseconds;
          _cravingSecondsLeft = max(0, (ms / 1000).ceil());
          shieldFinished = ms <= 0;
        }
      });
      if (shieldFinished) _completeShield();
    });
  }

  // ───────────────────────── Dialogs ─────────────────────────

  void _showDiscardConfirmationDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 8),
              Text("Discard Recording?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: const Text(
            "This breath test has not been logged. Are you sure you want to permanently erase this recording?",
            style: TextStyle(fontSize: 14, color: Colors.black87, height: 1.3),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text("Discard", style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _audioService.cancelRecording();
                setState(() {
                  _liveVolumeLevel = 0.0;
                });
              },
            ),
          ],
        );
      },
    );
  }

  void _showCravingCompleteAlert() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Urge Managed! 🎉"),
        content: const Text("Great job riding it out. Take a breath test now to see how you're doing!"),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Begin"))],
      ),
    );
  }

  void _showResetConfirmationDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text("Reset Storage History?"),
          content: const Text(
              "Erases all entries (including your baseline) from this device and restarts your streak from now."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                final UserProfile updated =
                    _profile.withQuitDate(DateTime.now(), status: SmokingStatus.quit);
                await widget.repo.resetProfileData(_pid);
                await widget.repo.saveProfile(updated);
                if (mounted) {
                  setState(() {
                    _profile = updated;
                    _historicalLogs.clear();
                    _isCravingModeActive = false;
                    _cravingSecondsLeft = 0;
                    _shieldExpiration = null;
                    _lastShieldEndTime = null;
                    _baselineSessionActive = false;
                    _sessionResults.clear();
                  });
                  widget.onProfileChanged(updated);
                  _syncReminders();
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800, foregroundColor: Colors.white),
              child: const Text("Wipe Memory Data"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteTempAudio(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _showValidationDialog(BuildContext context, AudioTestResult result) {
    TestContext selectedContext = TestContext.standardBaseline;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text("Breath Captured"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Sustained Exhalation: ${(result.duration.inMilliseconds / 1000).toStringAsFixed(2)}s"),
                  const SizedBox(height: 12),
                  DropdownButton<TestContext>(
                    value: selectedContext,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: TestContext.standardBaseline, child: Text("Standard test")),
                      DropdownMenuItem(value: TestContext.postExposure, child: Text("After secondhand smoke")),
                      DropdownMenuItem(value: TestContext.afterSmoking, child: Text("After I smoked")),
                    ],
                    onChanged: (val) {
                      if (val != null) setDialogState(() => selectedContext = val);
                    },
                  ),
                  if (selectedContext == TestContext.postExposure)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text("Passive exposure. Your streak is not affected.",
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                    ),
                  if (selectedContext == TestContext.afterSmoking)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text("Counts as a slip-up: your smoke-free streak will reset.",
                          style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  child: const Text("Discard", style: TextStyle(color: Colors.red)),
                  onPressed: () {
                    _deleteTempAudio(result.filePath);
                    Navigator.of(dialogContext).pop();
                  },
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (mounted) {
                      setState(() {
                        _historicalLogs.insert(
                          0,
                          BreathLog.create(
                            profileId: _pid,
                            kind: LogKind.acousticTest,
                            context: selectedContext,
                            timestamp: DateTime.now(),
                            duration: result.duration,
                            isManual: false,
                          ),
                        );
                        _sortLogsChronologically();
                      });
                    }
                    await _deleteTempAudio(result.filePath);
                    await _commitStateToDisk();
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: const Text("Save Metrics"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ───────────────────────── Baseline session ─────────────────────────

  void _startBaselineSession() {
    if (_currentStatus != BreathRecorderState.idle) return;
    setState(() {
      _baselineSessionActive = true;
      _sessionResults.clear();
    });
  }

  void _cancelBaselineSession() {
    setState(() {
      _baselineSessionActive = false;
      _sessionResults.clear();
    });
  }

  Future<void> _handleBaselineSessionResult(AudioTestResult result) async {
    await _deleteTempAudio(result.filePath);
    if (!mounted) return;

    setState(() {
      _sessionResults.add(_SessionResult(result.duration, DateTime.now()));
    });

    if (_sessionResults.length < TrackerLogic.baselineTestsRequired) {
      final secs = (result.duration.inMilliseconds / 1000).toStringAsFixed(1);
      _showSnack(
        "Test ${_sessionResults.length} of ${TrackerLogic.baselineTestsRequired} saved ($secs s). Rest about 30 seconds, then continue.",
        color: Colors.teal,
      );
      return;
    }
    await _finishBaselineSession();
  }

  Future<void> _finishBaselineSession() async {
    final List<double> secs =
        _sessionResults.map((r) => r.duration.inMilliseconds / 1000.0).toList();
    final double med = TrackerLogic.median(secs)!;
    final bool inconsistent = TrackerLogic.isInconsistent(secs);

    final bool? keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Your Baseline"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < secs.length; i++) Text("Test ${i + 1}: ${secs[i].toStringAsFixed(1)} s"),
            const SizedBox(height: 8),
            Text("Baseline (median): ${med.toStringAsFixed(1)} s",
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text("Future scores compare your tests to this number (100 = baseline).",
                style: TextStyle(fontSize: 12)),
            if (inconsistent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  "Your three results varied a lot. For a more reliable baseline, redo the session "
                  "with the phone in the same spot each time.",
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("Redo")),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text("Save Baseline")),
        ],
      ),
    );

    if (!mounted) return;

    if (keep == true) {
      setState(() {
        for (final r in _sessionResults) {
          _historicalLogs.add(BreathLog.create(
            profileId: _pid,
            kind: LogKind.baselineSession,
            context: TestContext.standardBaseline,
            timestamp: r.timestamp,
            duration: r.duration,
            isManual: false,
          ));
        }
        _sortLogsChronologically();
        _baselineSessionActive = false;
        _sessionResults.clear();
      });
      await _commitStateToDisk();
      _showSnack("Baseline saved. Your Breath Score is now personal to you.", color: Colors.teal);
    } else {
      setState(() => _sessionResults.clear());
      _showSnack("No problem — let's run the three tests again.");
    }
  }

  // ───────────────────────── Logging / persistence ─────────────────────────

  Future<void> _handleBackdatedExposureLogging() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      helpText: "SELECT RELAPSE DATE",
    );

    if (pickedDate == null || !mounted) return;

    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: "SELECT RELAPSE TIME",
    );

    if (pickedTime == null || !mounted) return;

    DateTime targetTimestamp = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    final now = DateTime.now();
    if (targetTimestamp.isAfter(now)) targetTimestamp = now;

    setState(() {
      _historicalLogs.insert(
        0,
        BreathLog.create(
          profileId: _pid,
          kind: LogKind.backdatedRelapse,
          context: TestContext.relapseSlip,
          timestamp: targetTimestamp,
          isManual: true,
        ),
      );
      _sortLogsChronologically();
    });

    await _commitStateToDisk();
    _showSnack("Backdated exposure logged successfully. Timeline metrics updated.", color: Colors.blueGrey);
  }

  Future<void> _loadPersistedDatabase() async {
    final List<BreathLog> savedLogs = await widget.repo.loadLogs(_pid);
    final DateTime? savedCooldown = await widget.repo.loadShieldCooldown(_pid);
    if (!mounted) return;

    setState(() {
      _lastShieldEndTime = savedCooldown;
      _historicalLogs
        ..clear()
        ..addAll(savedLogs);
      _sortLogsChronologically();
    });
    _syncReminders();
  }

  void _sortLogsChronologically() {
    _historicalLogs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> _commitStateToDisk() async {
    await widget.repo.saveLogs(_pid, _historicalLogs);
    _syncReminders();
  }

  /// Keeps scheduled notifications in line with settings and the current streak.
  Future<void> _syncReminders() async {
    final AppSettings st = widget.controller.settings;
    final DateTime? streakStart = (st.milestoneAlertsEnabled && !_profile.quitDate.isAfter(DateTime.now()))
        ? TrackerLogic.streakAnchor(_profile.quitDate, _historicalLogs)
        : null;
    await ReminderService.instance.sync(st, streakStart);
  }

  /// Called by Settings after anything changed (settings, restore, deleted locations).
  Future<void> _onSettingsDataChanged() async {
    await _loadPersistedDatabase();
    await _syncReminders();
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          controller: widget.controller,
          repo: widget.repo,
          onDataChanged: () async {
            await _onSettingsDataChanged();
            // A restore may have replaced the profile itself.
            final UserProfile? stored = await widget.repo.loadActiveProfile();
            if (stored != null && mounted && stored.toJson().toString() != _profile.toJson().toString()) {
              await widget.onDataReplaced();
            }
          },
          onEditProfile: _editProfile,
          onResetProfile: _showResetConfirmationDialog,
        ),
      ),
    );
  }

  void _handleStateTransitions(BreathRecorderState newState) {
    if (!mounted) return;

    if (newState == BreathRecorderState.recording && _currentStatus != BreathRecorderState.recording) {
      HapticFeedback.mediumImpact();
    }

    setState(() {
      if (newState == BreathRecorderState.idle) _liveVolumeLevel = 0.0;
      _currentStatus = newState;
    });
  }

  // ───────────────────────── Metrics ─────────────────────────
  // The maths lives in logic/tracker_logic.dart (unit-tested); these are thin wrappers.

  double? get _baselineSeconds => TrackerLogic.baselineSeconds(_historicalLogs);

  double? _currentSeconds(Set<TestContext> contexts) =>
      TrackerLogic.currentSeconds(_historicalLogs, contexts, DateTime.now());

  int? _scoreFor(double? seconds) => TrackerLogic.scoreFor(seconds, _baselineSeconds);

  String _deltaText(int score) {
    final int d = score - 100;
    return "${d > 0 ? '+' : ''}$d% vs baseline";
  }

  Duration _getTimeSinceLastExposure() =>
      TrackerLogic.streakElapsed(_profile.quitDate, _historicalLogs, DateTime.now());

  Duration _longestStreak() => TrackerLogic.longestStreak(_profile.quitDate, _historicalLogs, DateTime.now());

  String _fmtStreak(Duration d) {
    if (d.inDays >= 1) return "${d.inDays}d ${d.inHours % 24}h";
    if (d.inHours >= 1) return "${d.inHours}h ${d.inMinutes % 60}m";
    return "${d.inMinutes}m";
  }

  Widget? _buildSavingsLine(Duration elapsed) {
    final int? cpd = _profile.cigarettesPerDay;
    if (cpd == null) return null;

    final int avoided = TrackerLogic.cigarettesAvoided(elapsed, cpd);
    String text = "≈ $avoided cigarettes not smoked";
    final double? price = _profile.pricePerPack;
    if (price != null) {
      text += "  ·  ≈ ${Fmt.money(context, TrackerLogic.moneySaved(avoided, price))} saved";
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }

  // ───────────────────────── Export ─────────────────────────

  void _openExport() {
    showExportSheet(context, profile: _profile, logs: List<BreathLog>.of(_historicalLogs));
  }

  // ───────────────────────── Airway Shield ─────────────────────────

  Future<void> _startCravingDelay() async {
    if (_isCravingModeActive || _isStartingShield) return;
    _isStartingShield = true;

    try {
      final DateTime? storedCooldown = await widget.repo.loadShieldCooldown(_pid);
      if (storedCooldown != null) {
        _lastShieldEndTime = storedCooldown;
      }

      if (_lastShieldEndTime != null) {
        final int elapsedMinutes = DateTime.now().difference(_lastShieldEndTime!).inMinutes;
        if (elapsedMinutes < 15) {
          final int minutesLeft = 15 - elapsedMinutes;
          _showSnack("Airway Shield is cooling down. Please wait $minutesLeft more minutes.",
              color: Colors.orange.shade800);
          return;
        }
      }

      HapticFeedback.lightImpact();
      double? lat;
      double? lng;

      try {
        // Location is only read when the user turned it on in Settings.
        if (!widget.controller.settings.saveCravingLocation) throw StateError('location off');
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          final Position pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium,
            timeLimit: const Duration(seconds: 8),
          );
          lat = pos.latitude;
          lng = pos.longitude;
        }
      } catch (_) {
        // Location is optional; the shield still starts without it.
      }

      if (!mounted) return;

      final DateTime expiration = DateTime.now().add(const Duration(minutes: 10));
      await widget.repo.saveShieldExpiration(_pid, expiration);

      setState(() {
        _shieldExpiration = expiration;
        _isCravingModeActive = true;
        _cravingSecondsLeft = 600;

        _historicalLogs.insert(
          0,
          BreathLog.create(
            profileId: _pid,
            kind: LogKind.cravingMarker,
            context: TestContext.cravingThreat,
            timestamp: DateTime.now(),
            isManual: false,
            latitude: lat,
            longitude: lng,
          ),
        );
      });
      await _commitStateToDisk();
    } finally {
      _isStartingShield = false;
    }
  }

  Future<void> _handleActiveSlipUp() async {
    HapticFeedback.vibrate();

    final now = DateTime.now();
    _lastShieldEndTime = now;
    await widget.repo.saveShieldCooldown(_pid, now);
    await widget.repo.clearShieldExpiration(_pid);

    if (!mounted) return;

    setState(() {
      _isCravingModeActive = false;
      _cravingSecondsLeft = 0;
      _shieldExpiration = null;

      // Remove only the CURRENT shield's marker (the most recent one).
      final int idx = _historicalLogs.indexWhere((log) => log.kind == LogKind.cravingMarker);
      if (idx != -1) _historicalLogs.removeAt(idx);

      _historicalLogs.insert(
        0,
        BreathLog.create(
          profileId: _pid,
          kind: LogKind.userSlip,
          context: TestContext.relapseSlip,
          timestamp: now,
          isManual: true,
        ),
      );

      _sortLogsChronologically();
    });

    await _commitStateToDisk();

    _showSnack("Streak reset. 15-minute Airway Shield cool-down initiated.", color: Colors.blueGrey);
  }

  // ───────────────────────── Test button ─────────────────────────

  Future<void> _onTestButtonPressed() async {
    if (_currentStatus == BreathRecorderState.recording) {
      await _audioService.stopRecording();
      return;
    }
    if (_currentStatus != BreathRecorderState.idle || _isStartingTest) return;

    setState(() => _isStartingTest = true);
    try {
      if (!await _audioService.hasPermission()) {
        _showSnack("Microphone permission is required. Enable it in system settings.",
            color: Colors.red.shade700);
        return;
      }
      await _audioService.ensureCalibrated();
      if (!mounted) return;
      await _audioService.startRecording();
    } catch (e) {
      _showSnack("Could not start the test: $e", color: Colors.red.shade700);
    } finally {
      if (mounted) setState(() => _isStartingTest = false);
    }
  }

  // ───────────────────────── Build ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final Duration elapsed = _getTimeSinceLastExposure();
    final double? baseline = _baselineSeconds;
    final int? breathScore = _scoreFor(_currentSeconds({TestContext.standardBaseline}));
    final int? exposureScore =
        _scoreFor(_currentSeconds({TestContext.postExposure, TestContext.afterSmoking}));
    final Widget? savings = _buildSavingsLine(elapsed);
    final bool planning = _profile.quitDate.isAfter(DateTime.now());

    String breathSubtitle;
    if (baseline == null) {
      breathSubtitle = "set your baseline";
    } else if (breathScore == null) {
      breathSubtitle = "no tests in ${TrackerLogic.scoreWindowDays} days";
    } else {
      breathSubtitle = _deltaText(breathScore);
    }

    String exposureSubtitle;
    if (baseline == null) {
      exposureSubtitle = "needs a baseline";
    } else if (exposureScore == null) {
      exposureSubtitle = "no exposure tests yet";
    } else {
      exposureSubtitle = _deltaText(exposureScore);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("AirEngine Telemetry"),
        backgroundColor: Colors.teal.shade100,
        leading: _currentStatus == BreathRecorderState.recording
            ? IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.black87),
                tooltip: "Discard current recording",
                onPressed: () => _showDiscardConfirmationDialog(context),
              )
            : null,
        actions: [
          IconButton(icon: const Icon(Icons.ios_share_rounded), tooltip: "Share with clinician", onPressed: _openExport),
          IconButton(
            icon: const Icon(Icons.edit_calendar),
            tooltip: "Log Forgotten Smoke",
            onPressed: _handleBackdatedExposureLogging,
          ),
          IconButton(icon: const Icon(Icons.settings_rounded), tooltip: "Settings", onPressed: _openSettings),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_isCravingModeActive) _buildCravingCountdownWidget(),
            Expanded(
              child: NestedScrollView(
                headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
                  return [
                    SliverToBoxAdapter(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            color: Colors.teal.shade800,
                            child: Column(
                              children: [
                                if (_profile.displayName.isNotEmpty)
                                  Text("Hi, ${_profile.displayName}",
                                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                Text(
                                  planning ? "STREAK STARTS ON YOUR QUIT DATE" : "SMOKE-FREE STREAK DURATION",
                                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  "${elapsed.inHours}h ${elapsed.inMinutes % 60}m ${elapsed.inSeconds % 60}s",
                                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                                ),
                                if (savings != null) savings,
                                const SizedBox(height: 8),
                                if (!_isCravingModeActive)
                                  ElevatedButton.icon(
                                    onPressed: _startCravingDelay,
                                    icon: const Icon(Icons.security),
                                    label: const Text("Activate Airway Shield"),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            color: Colors.teal.shade900,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    _buildScoreUnit("Breath Score", breathScore, breathSubtitle, Colors.tealAccent),
                                    _buildScoreUnit("After-Exposure Score", exposureScore, exposureSubtitle, Colors.redAccent),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                if (baseline != null)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text("Your baseline: ${baseline.toStringAsFixed(1)} s",
                                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: _currentStatus == BreathRecorderState.idle ? _startBaselineSession : null,
                                        child: const Text("Redo",
                                            style: TextStyle(
                                                color: Colors.tealAccent,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline)),
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: 4),
                                const Text(
                                  "100 = your own baseline. Wellness feature — not a medical diagnosis.",
                                  style: TextStyle(color: Colors.white54, fontSize: 9),
                                ),
                              ],
                            ),
                          ),
                          _buildBaselineCard(baseline),
                          MilestoneProgressCard(
                            quitTimestamp: DateTime.now().subtract(elapsed),
                          ),
                          _buildInsightsCard(),
                          _buildTrendLineChartVisualization(baseline),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _SliverTabBarDelegate(
                        TabBar(
                          controller: _timeframeTabController,
                          labelColor: Colors.teal.shade900,
                          unselectedLabelColor: Colors.grey.shade600,
                          indicatorColor: Colors.teal.shade700,
                          indicatorWeight: 3,
                          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          tabs: const [
                            Tab(text: "Today"),
                            Tab(text: "7 Days"),
                            Tab(text: "30 Days"),
                            Tab(text: "All Logs")
                          ],
                        ),
                      ),
                    ),
                  ];
                },
                body: TabBarView(
                  controller: _timeframeTabController,
                  children: [
                    _buildTimeframeFilteredList(0),
                    _buildTimeframeFilteredList(1),
                    _buildTimeframeFilteredList(2),
                    _buildTimeframeFilteredList(3),
                  ],
                ),
              ),
            ),
            _buildSensingBottomControl(),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreUnit(String label, int? score, String subtitle, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 2),
        Text(score == null ? "—" : "$score",
            style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
        Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }

  Widget _buildBaselineCard(double? baseline) {
    if (_baselineSessionActive) {
      final int done = _sessionResults.length;
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.teal.shade50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.teal.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("PERSONAL BASELINE · $done of ${TrackerLogic.baselineTestsRequired} done",
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.teal.shade800)),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: done / TrackerLogic.baselineTestsRequired,
              minHeight: 6,
              backgroundColor: Colors.white,
              color: Colors.teal.shade600,
            ),
            const SizedBox(height: 8),
            Text(
              "Use the button below for each test. Breathe in fully, blow out steadily, "
              "and keep the phone in the same spot every time.",
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.3),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _currentStatus == BreathRecorderState.idle ? _cancelBaselineSession : null,
                child: const Text("Cancel session"),
              ),
            ),
          ],
        ),
      );
    }

    if (baseline != null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("SET YOUR PERSONAL BASELINE",
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber.shade900)),
          const SizedBox(height: 6),
          Text(
            "Phone microphones aren't medical instruments, so your score is measured against YOU. "
            "Three quick tests give the app a reliable starting point.",
            style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.3),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _currentStatus == BreathRecorderState.idle ? _startBaselineSession : null,
            icon: const Icon(Icons.flag_rounded, size: 18),
            label: const Text("Start baseline (3 quick tests)"),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightsCard() {
    final int beaten = TrackerLogic.urgesBeaten(_historicalLogs, shieldActive: _isCravingModeActive);
    final int slips = TrackerLogic.slipUps(_historicalLogs);
    final Duration longest = _longestStreak();

    final PeakUrge? peak = TrackerLogic.peakUrge(_historicalLogs);
    final String? peakText =
        peak == null ? null : "Most of your urges hit in the ${peak.bucket} (${peak.count} of ${peak.total}).";

    Widget stat(String label, String value) {
      return Expanded(
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal.shade800)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("YOUR PROGRESS",
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade700, letterSpacing: 0.5)),
          const SizedBox(height: 10),
          Row(
            children: [
              stat("Urges beaten", "$beaten"),
              stat("Slip-ups", "$slips"),
              stat("Longest streak", _fmtStreak(longest)),
            ],
          ),
          if (peakText != null) ...[
            const SizedBox(height: 10),
            Text(peakText, style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
          ],
        ],
      ),
    );
  }

  Widget _buildCravingCountdownWidget() {
    final int min = _cravingSecondsLeft ~/ 60;
    final int sec = _cravingSecondsLeft % 60;

    return Container(
      color: Colors.orange.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.security, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                "SHIELD ACTIVE: ${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: _handleActiveSlipUp,
            icon: const Icon(Icons.smoking_rooms, color: Colors.white, size: 14),
            label: const Text("I Smoked",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
            style: TextButton.styleFrom(
              backgroundColor: Colors.red.shade800,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendLineChartVisualization(double? baseline) {
    final List<BreathLog> rawBaselineLogs = _historicalLogs
        .where((log) => log.context == TestContext.standardBaseline && log.duration.inMilliseconds > 0)
        .toList()
        .reversed
        .toList();

    if (rawBaselineLogs.isEmpty) {
      return Container(
        height: 140,
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.teal.shade50.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.teal.shade100),
        ),
        child: const Center(
          child: Text(
            "No standard tests available for charting yet.",
            style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    final DateTime oldestDate = rawBaselineLogs.first.timestamp;
    final int totalSpanDays = DateTime.now().difference(oldestDate).inDays;

    final List<Map<String, dynamic>> chartDataPoints = [];
    String timeGroupingLabel = "Daily View";

    if (totalSpanDays > 180) {
      timeGroupingLabel = "Monthly Averages";
      final Map<String, List<double>> monthlyBuckets = {};
      final Map<String, DateTime> monthlyRepresentativeDate = {};

      for (var log in rawBaselineLogs) {
        final DateTime dt = log.timestamp;
        final String key = "${dt.year}-${dt.month.toString().padLeft(2, '0')}";
        final double sec = log.duration.inMilliseconds / 1000.0;

        monthlyBuckets.putIfAbsent(key, () => []).add(sec);
        monthlyRepresentativeDate[key] = DateTime(dt.year, dt.month, 1);
      }

      monthlyBuckets.forEach((key, values) {
        final double avgSec = values.reduce((a, b) => a + b) / values.length;
        chartDataPoints.add({
          'timestamp': monthlyRepresentativeDate[key],
          'durationSec': avgSec,
        });
      });
    } else if (totalSpanDays > 45) {
      timeGroupingLabel = "Weekly Averages";
      final Map<int, List<double>> weeklyBuckets = {};
      final Map<int, DateTime> weeklyRepresentativeDate = {};

      for (var log in rawBaselineLogs) {
        final DateTime dt = log.timestamp;
        final int weekKey = dt.year * 100 + (dt.difference(DateTime(dt.year, 1, 1)).inDays / 7).floor();
        final double sec = log.duration.inMilliseconds / 1000.0;

        weeklyBuckets.putIfAbsent(weekKey, () => []).add(sec);
        weeklyRepresentativeDate.putIfAbsent(weekKey, () => dt);
      }

      weeklyBuckets.forEach((key, values) {
        final double avgSec = values.reduce((a, b) => a + b) / values.length;
        chartDataPoints.add({
          'timestamp': weeklyRepresentativeDate[key],
          'durationSec': avgSec,
        });
      });
    } else {
      timeGroupingLabel = "High-Fidelity Log";
      for (var log in rawBaselineLogs) {
        chartDataPoints.add({
          'timestamp': log.timestamp,
          'durationSec': log.duration.inMilliseconds / 1000.0,
        });
      }
    }

    chartDataPoints.sort((a, b) => (a['timestamp'] as DateTime).compareTo(b['timestamp'] as DateTime));

    double minDurationSec = double.infinity;
    double maxDurationSec = 0;

    for (var point in chartDataPoints) {
      final double sec = point['durationSec'] as double;
      if (sec < minDurationSec) minDurationSec = sec;
      if (sec > maxDurationSec) maxDurationSec = sec;
    }

    if (minDurationSec == double.infinity) minDurationSec = 0;

    // Keep the baseline line inside the visible range.
    double lowForRange = minDurationSec;
    double highForRange = maxDurationSec;
    if (baseline != null) {
      lowForRange = min(lowForRange, baseline);
      highForRange = max(highForRange, baseline);
    }

    final double yAxisMin = max(0.0, lowForRange - 2.0);
    final double yAxisMax = highForRange + 3.0;

    final List<FlSpot> spots = [];
    for (int i = 0; i < chartDataPoints.length; i++) {
      spots.add(FlSpot(i.toDouble(), chartDataPoints[i]['durationSec'] as double));
    }

    return Container(
      height: 255,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.insights_rounded, size: 16, color: Colors.teal),
                  const SizedBox(width: 6),
                  Text(
                    "CAPACITY TREND ($timeGroupingLabel)",
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Peak: ${maxDurationSec.toStringAsFixed(1)}s",
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: max(1.0, (spots.length - 1).toDouble()),
                minY: yAxisMin,
                maxY: yAxisMax,
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (baseline != null)
                      HorizontalLine(
                        y: baseline,
                        color: Colors.orange.shade400,
                        strokeWidth: 1.5,
                        dashArray: [6, 4],
                      ),
                  ],
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) {
                    return FlLine(
                      color: Colors.grey.shade100,
                      strokeWidth: 1,
                    );
                  },
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (value, meta) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 4.0),
                          child: Text(
                            "${value.toStringAsFixed(0)}s",
                            style: TextStyle(color: Colors.grey.shade500, fontSize: 10, fontWeight: FontWeight.w500),
                            textAlign: TextAlign.right,
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: max(1.0, (spots.length / 4).floor().toDouble()),
                      getTitlesWidget: (value, meta) {
                        if (value != value.roundToDouble()) return const SizedBox.shrink();
                        final int index = value.toInt();
                        if (index < 0 || index >= chartDataPoints.length) return const SizedBox.shrink();
                        final DateTime dt = chartDataPoints[index]['timestamp'] as DateTime;

                        final String labelText =
                            totalSpanDays > 180 ? Fmt.monthYear(context, dt) : Fmt.monthDay(context, dt);

                        return Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Text(
                            labelText,
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 9, fontWeight: FontWeight.w500),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: Colors.teal.shade600,
                    barWidth: 3.5,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      show: spots.length < 15,
                      getDotPainter: (spot, percent, barData, index) {
                        return FlDotCirclePainter(
                          radius: 4,
                          color: Colors.white,
                          strokeWidth: 2,
                          strokeColor: Colors.teal.shade700,
                        );
                      },
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          Colors.teal.shade300.withValues(alpha: 0.3),
                          Colors.teal.shade50.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (baseline != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text("- - - your baseline (${baseline.toStringAsFixed(1)}s)",
                  style: TextStyle(fontSize: 9, color: Colors.orange.shade700)),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeframeFilteredList(int tabIndex) {
    final now = DateTime.now();
    final List<BreathLog> filtered = _historicalLogs.where((log) {
      final DateTime time = log.timestamp;
      if (tabIndex == 0) return time.day == now.day && time.month == now.month && time.year == now.year;
      if (tabIndex == 1) return time.isAfter(now.subtract(const Duration(days: 7)));
      if (tabIndex == 2) return time.isAfter(now.subtract(const Duration(days: 30)));
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text("No records for this timeframe", style: TextStyle(color: Colors.grey.shade500)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final item = filtered[index];
        final DateTime dt = item.timestamp;
        final double dur = item.duration.inMilliseconds / 1000.0;
        final TestContext ctx = item.context;

        IconData icon = Icons.air_rounded;
        Color iconColor = Colors.teal.shade700;
        Color bgColor = Colors.teal.shade50;
        String title = "Standard Exhale";

        if (item.kind == LogKind.trackingStart) {
          icon = Icons.flag_rounded;
          title = "Tracking Started";
        } else if (item.kind == LogKind.baselineSession) {
          icon = Icons.balance_rounded;
          title = "Baseline Test";
        } else if (ctx == TestContext.postExposure) {
          icon = Icons.masks_rounded;
          iconColor = Colors.amber.shade800;
          bgColor = Colors.amber.shade50;
          title = "After Secondhand Smoke";
        } else if (ctx == TestContext.afterSmoking) {
          icon = Icons.smoking_rooms_rounded;
          iconColor = Colors.red.shade700;
          bgColor = Colors.red.shade50;
          title = "After Smoking";
        } else if (ctx == TestContext.relapseSlip) {
          icon = Icons.smoking_rooms_rounded;
          iconColor = Colors.red.shade700;
          bgColor = Colors.red.shade50;
          title = "Relapse";
        } else if (ctx == TestContext.cravingThreat) {
          icon = Icons.security_rounded;
          iconColor = Colors.orange.shade800;
          bgColor = Colors.orange.shade50;
          title = "Shield Active Trigger";
        }

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: bgColor,
              child: Icon(icon, color: iconColor, size: 20),
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: Text(Fmt.dateTime(context, dt)),
            trailing: dur > 0
                ? Text("${Fmt.seconds(context, dur)}s", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))
                : null,
          ),
        );
      },
    );
  }

  Widget _buildSensingBottomControl() {
    final bool isRecording = _currentStatus == BreathRecorderState.recording;
    final bool isCalibrating = _currentStatus == BreathRecorderState.calibrating;

    String hint;
    if (isCalibrating) {
      hint = "Stay quiet for a moment — measuring room noise...";
    } else if (isRecording && !_audioService.hasBreathStarted) {
      hint = "Take a deep breath, then blow steadily toward the microphone.";
    } else if (isRecording) {
      hint = "Keep blowing — the test ends when you stop.";
    } else if (_baselineSessionActive) {
      hint = "Same spot every time: phone about 10 cm (4 in) from your mouth. Rest ~30 s between tests.";
    } else {
      hint = "Tip: hold your phone about 10 cm (4 in) from your mouth, in the same spot every test.";
    }

    final String idleLabel = _baselineSessionActive
        ? "Baseline Test ${min(_sessionResults.length + 1, TrackerLogic.baselineTestsRequired)} of ${TrackerLogic.baselineTestsRequired}"
        : "Begin Exhale Capacity Test";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isRecording || isCalibrating)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: LinearProgressIndicator(
                value: _liveVolumeLevel,
                backgroundColor: Colors.grey.shade200,
                color: isRecording ? Colors.teal : Colors.orange,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(hint, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isRecording ? Colors.red.shade700 : Colors.teal.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(isRecording ? Icons.stop_rounded : Icons.mic_rounded),
              label: Text(
                isRecording
                    ? "Stop & Save Exhale"
                    : (isCalibrating ? "Calibrating Microphone..." : idleLabel),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              onPressed: (isCalibrating || (_isStartingTest && !isRecording)) ? null : _onTestButtonPressed,
            ),
          ),
        ],
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar _tabBar;

  _SliverTabBarDelegate(this._tabBar);

  @override
  double get minExtent => _tabBar.preferredSize.height;

  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Colors.white,
      child: _tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return _tabBar != oldDelegate._tabBar;
  }
}
