import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'breath_audio_service.dart';
import 'models/breath_log.dart';
import 'models/user_profile.dart';
import 'onboarding_screen.dart';
import 'repositories/app_repository.dart';
import 'widgets/milestone_progress_card.dart';

class _SessionResult {
  final Duration duration;
  final DateTime timestamp;
  const _SessionResult(this.duration, this.timestamp);
}

class BreathTestScreen extends StatefulWidget {
  final AppRepository repo;
  final UserProfile profile;

  const BreathTestScreen({super.key, required this.repo, required this.profile});

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
  static const int _baselineTestsRequired = 3;
  static const int _scoreWindowDays = 30;
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

    if (_sessionResults.length < _baselineTestsRequired) {
      final secs = (result.duration.inMilliseconds / 1000).toStringAsFixed(1);
      _showSnack(
        "Test ${_sessionResults.length} of $_baselineTestsRequired saved ($secs s). Rest about 30 seconds, then continue.",
        color: Colors.teal,
      );
      return;
    }
    await _finishBaselineSession();
  }

  Future<void> _finishBaselineSession() async {
    final List<double> secs =
        _sessionResults.map((r) => r.duration.inMilliseconds / 1000.0).toList();
    final double med = _median(secs)!;
    final double spread = (secs.reduce(max) - secs.reduce(min)) / (med <= 0 ? 1 : med);
    final bool inconsistent = spread > 0.4;

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
  }

  void _sortLogsChronologically() {
    _historicalLogs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> _commitStateToDisk() async {
    await widget.repo.saveLogs(_pid, _historicalLogs);
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

  double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = List<double>.from(values)..sort();
    final int mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// Personal baseline = median of the 3 most recent guided baseline-session tests.
  double? get _baselineSeconds {
    final session = _historicalLogs
        .where((l) => l.kind == LogKind.baselineSession && l.duration.inMilliseconds > 0)
        .take(_baselineTestsRequired)
        .map((l) => l.duration.inMilliseconds / 1000.0)
        .toList();
    return _median(session);
  }

  /// Median of the latest (up to 3) tests in [contexts] within the scoring window.
  double? _currentSeconds(Set<TestContext> contexts) {
    final cutoff = DateTime.now().subtract(const Duration(days: _scoreWindowDays));
    final recent = _historicalLogs
        .where((l) =>
            contexts.contains(l.context) && l.duration.inMilliseconds > 0 && l.timestamp.isAfter(cutoff))
        .take(3)
        .map((l) => l.duration.inMilliseconds / 1000.0)
        .toList();
    return _median(recent);
  }

  /// 100 = your own baseline. Above 100 = better than baseline.
  int? _scoreFor(double? seconds) {
    final base = _baselineSeconds;
    if (seconds == null || base == null || base <= 0) return null;
    return (seconds / base * 100).round();
  }

  String _deltaText(int score) {
    final int d = score - 100;
    return "${d > 0 ? '+' : ''}$d% vs baseline";
  }

  bool _isRelapseContext(TestContext c) => c == TestContext.relapseSlip || c == TestContext.afterSmoking;

  /// Streak = time since the later of (quit date, last slip-up / after-smoking test).
  /// A planned (future) quit date shows 0 until it arrives.
  Duration _getTimeSinceLastExposure() {
    final now = DateTime.now();
    DateTime anchor = _profile.quitDate;

    for (final log in _historicalLogs) {
      if (_isRelapseContext(log.context) && log.timestamp.isAfter(anchor)) {
        anchor = log.timestamp;
      }
    }

    final d = now.difference(anchor);
    return d.isNegative ? Duration.zero : d;
  }

  Duration _longestStreak() {
    final now = DateTime.now();
    final quit = _profile.quitDate;
    if (quit.isAfter(now)) return Duration.zero;

    final List<DateTime> points = [
      quit,
      ..._historicalLogs
          .where((l) => _isRelapseContext(l.context) && l.timestamp.isAfter(quit))
          .map((l) => l.timestamp),
    ];
    points.sort();
    points.add(now);

    Duration best = Duration.zero;
    for (int i = 1; i < points.length; i++) {
      final d = points[i].difference(points[i - 1]);
      if (d > best) best = d;
    }
    return best;
  }

  String _fmtStreak(Duration d) {
    if (d.inDays >= 1) return "${d.inDays}d ${d.inHours % 24}h";
    if (d.inHours >= 1) return "${d.inHours}h ${d.inMinutes % 60}m";
    return "${d.inMinutes}m";
  }

  String _timeBucket(int hour) {
    if (hour >= 5 && hour < 11) return "morning";
    if (hour >= 11 && hour < 15) return "midday";
    if (hour >= 15 && hour < 19) return "afternoon";
    if (hour >= 19) return "evening";
    return "late night";
  }

  Widget? _buildSavingsLine(Duration elapsed) {
    final int? cpd = _profile.cigarettesPerDay;
    if (cpd == null) return null;

    final double days = elapsed.inSeconds / 86400.0;
    final int avoided = (days * cpd).floor();
    String text = "≈ $avoided cigarettes not smoked";
    final double? price = _profile.pricePerPack;
    if (price != null) {
      text += "  ·  ≈ \$${(avoided / 20.0 * price).toStringAsFixed(2)} saved";
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }

  // ───────────────────────── Export ─────────────────────────

  Future<void> _exportBiometricDataSecurely({DateTime? startDate, DateTime? endDate}) async {
    final StringBuffer csvBuffer = StringBuffer();
    csvBuffer.writeln("Timestamp_ISO8601_UTC,Medical_Context,Exhale_Duration_Sec,Latitude,Longitude,Data_Ingestion_Type");

    final chronologicalLogs = _historicalLogs.reversed.where((log) {
      final DateTime logTime = log.timestamp;
      if (startDate != null && logTime.isBefore(startDate)) return false;
      if (endDate != null && logTime.isAfter(endDate.add(const Duration(hours: 23, minutes: 59, seconds: 59)))) {
        return false;
      }
      return true;
    }).toList();

    if (chronologicalLogs.isEmpty) {
      _showSnack("No records found within the selected date range.", color: Colors.orange);
      return;
    }

    for (var log in chronologicalLogs) {
      final double durationSec = log.duration.inMilliseconds / 1000.0;

      String contextStr = "BaselineCapacity";
      switch (log.context) {
        case TestContext.standardBaseline:
          contextStr = "BaselineCapacity";
          break;
        case TestContext.postExposure:
          contextStr = "PostExposure";
          break;
        case TestContext.relapseSlip:
          contextStr = "RelapseSlip";
          break;
        case TestContext.cravingThreat:
          contextStr = "CravingDeflectedThreat";
          break;
        case TestContext.afterSmoking:
          contextStr = "AfterSmoking";
          break;
      }

      final String latStr = log.latitude != null ? log.latitude!.toStringAsFixed(4) : "";
      final String lngStr = log.longitude != null ? log.longitude!.toStringAsFixed(4) : "";
      final String statusStr = log.kind == LogKind.baselineSession
          ? "BaselineSession"
          : (log.isManual ? "ManualInput" : "AcousticSignalProcessing");

      csvBuffer.writeln("${log.timestamp.toUtc().toIso8601String()},$contextStr,$durationSec,$latStr,$lngStr,$statusStr");
    }

    try {
      final Directory tempDir = await getTemporaryDirectory();
      final File csvFile = File('${tempDir.path}/AirEngine_Pulmonary_Export.csv');
      await csvFile.writeAsString(csvBuffer.toString());

      final XFile xFile = XFile(csvFile.path);
      final RenderBox? box = mounted ? context.findRenderObject() as RenderBox? : null;
      final Rect? sharePositionOrigin = box != null ? box.localToGlobal(Offset.zero) & box.size : null;

      await Share.shareXFiles(
        [xFile],
        subject: 'AirEngine Biometric Telemetry Report',
        sharePositionOrigin: sharePositionOrigin,
      );

      await Future.delayed(const Duration(seconds: 2));
      if (await csvFile.exists()) {
        await csvFile.delete();
      }
    } catch (e) {
      _showSnack("Export operation error: $e");
    }
  }

  void _showExportFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext sheetContext) {
        final now = DateTime.now();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Export Telemetry Report",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 4),
                Text("Select chronological parameters for CSV data payload generation.",
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.date_range_rounded, color: Colors.teal),
                  title: const Text("Past 30 Days", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportBiometricDataSecurely(startDate: now.subtract(const Duration(days: 30)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today_rounded, color: Colors.teal),
                  title: const Text("Year to Date (Whole Year)", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportBiometricDataSecurely(startDate: DateTime(now.year, 1, 1));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded, color: Colors.teal),
                  title: const Text("All-Time Historical Ledger", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportBiometricDataSecurely();
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.tune_rounded, color: Colors.orange),
                  title: const Text("Custom Date Range...",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (!mounted) return;
                    final DateTimeRange? pickedRange = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
                      lastDate: DateTime.now(),
                      saveText: "EXPORT",
                    );
                    if (pickedRange != null) {
                      _exportBiometricDataSecurely(startDate: pickedRange.start, endDate: pickedRange.end);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
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
      breathSubtitle = "no tests in $_scoreWindowDays days";
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
          IconButton(icon: const Icon(Icons.person_rounded), tooltip: "Edit profile", onPressed: _editProfile),
          IconButton(icon: const Icon(Icons.share), tooltip: "Secure Data Export", onPressed: _showExportFilterBottomSheet),
          IconButton(
            icon: const Icon(Icons.edit_calendar),
            tooltip: "Log Forgotten Smoke",
            onPressed: _handleBackdatedExposureLogging,
          ),
          IconButton(icon: const Icon(Icons.refresh), tooltip: "Reset data", onPressed: _showResetConfirmationDialog)
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
                                    label: const Text("Activate Airway Shield (Log GPS Trigger)"),
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
            Text("PERSONAL BASELINE · $done of $_baselineTestsRequired done",
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.teal.shade800)),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: done / _baselineTestsRequired,
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
    final int beaten = max(
      0,
      _historicalLogs.where((l) => l.kind == LogKind.cravingMarker).length - (_isCravingModeActive ? 1 : 0),
    );
    final int slips = _historicalLogs.where((l) => l.kind == LogKind.userSlip).length;
    final Duration longest = _longestStreak();

    final urgeTimes = _historicalLogs
        .where((l) => l.kind == LogKind.cravingMarker || l.kind == LogKind.userSlip)
        .map((l) => l.timestamp)
        .toList();

    String? peakText;
    if (urgeTimes.length >= 5) {
      final Map<String, int> counts = {};
      for (final t in urgeTimes) {
        counts.update(_timeBucket(t.hour), (v) => v + 1, ifAbsent: () => 1);
      }
      final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (top.value / urgeTimes.length >= 0.4) {
        peakText = "Most of your urges hit in the ${top.key} (${top.value} of ${urgeTimes.length}).";
      }
    }

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
          color: Colors.teal.shade50.withOpacity(0.3),
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
            color: Colors.black.withOpacity(0.04),
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

                        final String labelText = totalSpanDays > 180
                            ? "${dt.month}/${dt.year.toString().substring(2)}"
                            : "${dt.month}/${dt.day}";

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
                          Colors.teal.shade300.withOpacity(0.3),
                          Colors.teal.shade50.withOpacity(0.0),
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
            subtitle: Text("${dt.month}/${dt.day}/${dt.year} @ ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}"),
            trailing: dur > 0
                ? Text("${dur.toStringAsFixed(1)}s", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))
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
        ? "Baseline Test ${min(_sessionResults.length + 1, _baselineTestsRequired)} of $_baselineTestsRequired"
        : "Begin Exhale Capacity Test";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
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