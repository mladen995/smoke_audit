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
import 'storage_service.dart';
import 'widgets/milestone_progress_card.dart';

enum TestContext {
  standardBaseline,
  postExposure,       // Secondhand / passive exposure
  relapseSlip,        // Active slip-ups / relapses (used in your calendar tool)
  cravingThreat,      // Active Shield / craving tracking
}

class BreathTestScreen extends StatefulWidget {
  const BreathTestScreen({super.key});

  @override
  State<BreathTestScreen> createState() => _BreathTestScreenState();
}

class _BreathTestScreenState extends State<BreathTestScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late BreathAudioService _audioService;
  late TabController _timeframeTabController;

  BreathRecorderState _currentStatus = BreathRecorderState.idle;
  double _liveVolumeLevel = 0.0;
  StreamSubscription<double>? _volumeSubscription;

  final List<Map<String, dynamic>> _historicalLogs = [];
  Timer? _tickerTimer;

  int _cravingSecondsLeft = 0;
  bool _isCravingModeActive = false;

  // 🕒 Cool-Down Variable to enforce the 15-minute clinical buffer window
  DateTime? _lastShieldEndTime;

  // Patient Demographic Variables (Morris-Temple Clinical Regression Inputs)
  final int _userChronologicalAge = 35;
  final String _userGender = "Male";
  final double _userHeightInches = 69.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timeframeTabController = TabController(length: 4, vsync: this);

    _timeframeTabController.addListener(() {
      if (!_timeframeTabController.indexIsChanging) {
        setState(() {});
      }
    });

    _audioService = BreathAudioService(
      onStateChanged: _handleStateTransitions,
      onRecordingComplete: (result) => _showValidationDialog(context, result),
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkRestoredShieldTimer();
    }
  }

  Future<void> _checkRestoredShieldTimer() async {
    DateTime? expirationTime = await StorageService.loadShieldExpiration();
    if (expirationTime != null) {
      final int remainingSeconds = expirationTime.difference(DateTime.now()).inSeconds;
      setState(() {
        if (remainingSeconds > 0) {
          _isCravingModeActive = true;
          _cravingSecondsLeft = remainingSeconds;
        } else {
          _isCravingModeActive = false;
          _cravingSecondsLeft = 0;
          _lastShieldEndTime = DateTime.now();
          StorageService.saveShieldCooldown(_lastShieldEndTime!);
          StorageService.clearShieldExpiration();
          _showCravingCompleteAlert();
        }
      });
    }
  }

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
            "This breath telemetry metadata has not been logged. Are you sure you want to permanently erase this recording cycle?",
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
                  _currentStatus = BreathRecorderState.idle;
                  _liveVolumeLevel = 0.0;
                });
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleBackdatedExposureLogging() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      helpText: "SELECT RELAPSE DATE",
    );

    if (pickedDate == null) return;
    if (!mounted) return;

    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: "SELECT RELAPSE TIME",
    );

    if (pickedTime == null) return;

    final DateTime targetTimestamp = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    setState(() {
      _historicalLogs.insert(0, {
        'path': 'RETROACTIVE_BACKDATED_LOG',
        'duration': Duration.zero,
        'context': TestContext.relapseSlip,
        'timestamp': targetTimestamp,
        'isManual': true,
        'latitude': null,
        'longitude': null,
      });

      _sortLogsChronologically();
    });

    await _commitStateToDisk();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Backdated exposure logged successfully. Timeline metrics updated."),
          backgroundColor: Colors.blueGrey,
        ),
      );
    }
  }

  Future<void> _loadPersistedDatabase() async {
    final List<Map<String, dynamic>> savedData = await StorageService.loadLogs();
    final DateTime? savedCooldown = await StorageService.loadShieldCooldown();

    setState(() {
      _lastShieldEndTime = savedCooldown;

      _historicalLogs.clear();
      if (savedData.isNotEmpty) {
        for (var log in savedData) {
          final int contextIdx = log['contextIndex'] ?? 0;
          TestContext parsedContext;
          switch (contextIdx) {
            case 1:
              parsedContext = TestContext.postExposure;
              break;
            case 2:
              parsedContext = TestContext.relapseSlip;
              break;
            case 3:
              parsedContext = TestContext.cravingThreat;
              break;
            default:
              parsedContext = TestContext.standardBaseline;
          }

          _historicalLogs.add({
            'path': log['path'],
            'duration': log['duration'],
            'context': parsedContext,
            'timestamp': log['timestamp'],
            'isManual': log['isManual'],
            'latitude': log['latitude'],
            'longitude': log['longitude'],
          });
        }
      } else {
        _historicalLogs.add({
          'path': 'FIRST_LAUNCH_BASELINE',
          'duration': const Duration(milliseconds: 3600),
          'context': TestContext.standardBaseline,
          'timestamp': DateTime.now().subtract(const Duration(hours: 24)),
          'isManual': true,
          'latitude': null,
          'longitude': null,
        });
      }
      _sortLogsChronologically();
    });
  }

  void _sortLogsChronologically() {
    _historicalLogs.sort((a, b) => (b['timestamp'] as DateTime).compareTo(a['timestamp'] as DateTime));
  }

  Future<void> _commitStateToDisk() async {
    await StorageService.persistLogs(_historicalLogs);
  }

  void _resetGlobalTimelineTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_isCravingModeActive && _cravingSecondsLeft > 0) {
          _cravingSecondsLeft--;
          if (_cravingSecondsLeft == 0) {
            _isCravingModeActive = false;
            _lastShieldEndTime = DateTime.now();
            StorageService.saveShieldCooldown(_lastShieldEndTime!);
            StorageService.clearShieldExpiration();
            _showCravingCompleteAlert();
          }
        }
      });
    });
  }

  void _handleStateTransitions(BreathRecorderState newState) {
    if (!mounted) return;

    if (newState == BreathRecorderState.recording && _currentStatus != BreathRecorderState.recording) {
      HapticFeedback.mediumImpact();
    } else if (newState == BreathRecorderState.idle) {
      _liveVolumeLevel = 0.0;
    }

    setState(() {
      _currentStatus = newState;
    });
  }

  int _calculateClinicalLungAge(TestContext focusContext) {
    final filtered = _historicalLogs
        .where((log) => log['context'] == focusContext && (log['duration'] as Duration).inMilliseconds > 0)
        .take(3)
        .toList();

    if (filtered.isEmpty) return _userChronologicalAge;

    double totalMs = 0;
    for (var item in filtered) {
      totalMs += (item['duration'] as Duration).inMilliseconds;
    }
    double averageSeconds = (totalMs / filtered.length) / 1000.0;

    double calculatedAge;
    if (_userGender == "Male") {
      calculatedAge = (2.870 * _userHeightInches) - (31.250 * averageSeconds) - 39.375;
    } else {
      calculatedAge = (3.560 * _userHeightInches) - (40.000 * averageSeconds) - 77.280;
    }

    Duration cleanStretch = _getTimeSinceLastExposure();
    double recoveryBonus = 1.5 * sqrt(cleanStretch.inMinutes / 60.0);

    int finalScore = (calculatedAge - recoveryBonus).round();
    return max(min(finalScore, 85), _userChronologicalAge - 5);
  }

  Duration _getTimeSinceLastExposure() {
    DateTime? lastRelapse;
    for (var log in _historicalLogs) {
      if (log['context'] == TestContext.relapseSlip || log['context'] == TestContext.postExposure) {
        if (lastRelapse == null || (log['timestamp'] as DateTime).isAfter(lastRelapse)) {
          lastRelapse = log['timestamp'];
        }
      }
    }
    if (lastRelapse == null) {
      return _historicalLogs.isNotEmpty ? DateTime.now().difference(_historicalLogs.last['timestamp']) : Duration.zero;
    }
    return DateTime.now().difference(lastRelapse);
  }

  Future<void> _exportBiometricDataSecurely({DateTime? startDate, DateTime? endDate}) async {
    final StringBuffer csvBuffer = StringBuffer();
    csvBuffer.writeln("Timestamp_ISO8601,Medical_Context,Exhale_Duration_Sec,Latitude,Longitude,Data_Ingestion_Type");

    final chronologicalLogs = _historicalLogs.reversed.where((log) {
      final DateTime logTime = log['timestamp'] as DateTime;
      if (startDate != null && logTime.isBefore(startDate)) return false;
      if (endDate != null && logTime.isAfter(endDate.add(const Duration(hours: 23, minutes: 59, seconds: 59)))) return false;
      return true;
    }).toList();

    if (chronologicalLogs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No records found within the selected date range."), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    for (var log in chronologicalLogs) {
      final double durationSec = (log['duration'] as Duration).inMilliseconds / 1000.0;

      String contextStr = "BaselineCapacity";
      switch (log['context'] as TestContext) {
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
      }

      final String latStr = log['latitude'] != null ? log['latitude'].toStringAsFixed(4) : "0.0000";
      final String lngStr = log['longitude'] != null ? log['longitude'].toStringAsFixed(4) : "0.0000";
      final String statusStr = log['isManual'] == true ? "ManualInput" : "AcousticSignalProcessing";

      csvBuffer.writeln("${(log['timestamp'] as DateTime).toIso8601String()},$contextStr,$durationSec,$latStr,$lngStr,$statusStr");
    }

    try {
      final Directory tempDir = await getTemporaryDirectory();
      final File csvFile = File('${tempDir.path}/AirEngine_Pulmonary_Export.csv');
      await csvFile.writeAsString(csvBuffer.toString());

      final XFile xFile = XFile(csvFile.path);
      final RenderBox? box = context.findRenderObject() as RenderBox?;
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export operation error context: $e")));
      }
    }
  }

  void _showExportFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        final now = DateTime.now();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Export Telemetry Report", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 4),
                Text("Select chronological parameters for CSV data payload generation.", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.date_range_rounded, color: Colors.teal),
                  title: const Text("Past 30 Days", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    _exportBiometricDataSecurely(startDate: now.subtract(const Duration(days: 30)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today_rounded, color: Colors.teal),
                  title: const Text("Year to Date (Whole Year)", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    _exportBiometricDataSecurely(startDate: DateTime(now.year, 1, 1));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded, color: Colors.teal),
                  title: const Text("All-Time Historical Ledger", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    _exportBiometricDataSecurely();
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.tune_rounded, color: Colors.orange),
                  title: const Text("Custom Date Range...", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  onTap: () async {
                    Navigator.pop(context);
                    final DateTimeRange? pickedRange = await showDateRangePicker(
                      context: this.context,
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

  Future<void> _startCravingDelay() async {
    final DateTime? storedCooldown = await StorageService.loadShieldCooldown();
    if (storedCooldown != null) {
      _lastShieldEndTime = storedCooldown;
    }

    if (_lastShieldEndTime != null) {
      final int elapsedMinutes = DateTime.now().difference(_lastShieldEndTime!).inMinutes;
      if (elapsedMinutes < 15) {
        final int minutesLeft = 15 - elapsedMinutes;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Airway Shield is cooling down. Please wait $minutesLeft more minutes."),
              backgroundColor: Colors.orange.shade800,
            ),
          );
        }
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
        Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
        lat = pos.latitude;
        lng = pos.longitude;
      }
    } catch (_) {}

    setState(() {
      _isCravingModeActive = true;
      _cravingSecondsLeft = 600;

      _historicalLogs.insert(0, {
        'path': 'CRAVING_TRIGGER_MARKER',
        'duration': Duration.zero,
        'context': TestContext.cravingThreat,
        'timestamp': DateTime.now(),
        'isManual': false,
        'latitude': lat,
        'longitude': lng,
      });
    });
    await _commitStateToDisk();
  }

  void _handleActiveSlipUp() async {
    HapticFeedback.vibrate();
    
    final now = DateTime.now();
    _lastShieldEndTime = now;
    StorageService.saveShieldCooldown(now);
    await StorageService.clearShieldExpiration();

    setState(() {
      _isCravingModeActive = false;
      _cravingSecondsLeft = 0;

      _historicalLogs.removeWhere((log) => log['path'] == 'CRAVING_TRIGGER_MARKER' && log['duration'] == Duration.zero);

      _historicalLogs.insert(0, {
        'path': 'USER_DECLARED_SLIP_UP',
        'duration': Duration.zero,
        'context': TestContext.relapseSlip,
        'timestamp': now,
        'isManual': true,
        'latitude': null,
        'longitude': null,
      });

      _sortLogsChronologically();
    });

    await _commitStateToDisk();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Streak reset. 15-minute Airway Shield cool-down initiated."),
          backgroundColor: Colors.blueGrey,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _showCravingCompleteAlert() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Urge Managed! 🎉"),
        content: const Text("Your airway score is intact. Test capacity right now to track performance values!"),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Begin"))],
      ),
    );
  }

  void _showResetConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Reset Storage History?"),
          content: const Text("Erases all entries permanently off local mobile hardware disks."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                setState(() {
                  _historicalLogs.clear();
                  _isCravingModeActive = false;
                  _cravingSecondsLeft = 0;
                  _lastShieldEndTime = null;
                });
                await _commitStateToDisk();
                await StorageService.clearShieldExpiration();
                await StorageService.clearShieldCooldown();
                if (context.mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800, foregroundColor: Colors.white),
              child: const Text("Wipe Memory Data"),
            ),
          ],
        );
      },
    );
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
              content: Text("Sustained Exhalation: ${(result.duration.inMilliseconds / 1000).toStringAsFixed(2)}s"),
              actions: [
                DropdownButton<TestContext>(
                  value: selectedContext == TestContext.postExposure ? TestContext.postExposure : TestContext.standardBaseline,
                  items: const [
                    DropdownMenuItem(value: TestContext.standardBaseline, child: Text("Standard Baseline")),
                    DropdownMenuItem(value: TestContext.postExposure, child: Text("Post-Exposure")),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedContext = val);
                  },
                ),
                TextButton(
                  child: const Text("Discard", style: TextStyle(color: Colors.red)),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
                ElevatedButton(
                  onPressed: () async {
                    setState(() {
                      _historicalLogs.insert(0, {
                        'path': result.filePath,
                        'duration': result.duration,
                        'context': selectedContext,
                        'timestamp': DateTime.now(),
                        'isManual': false,
                        'latitude': null,
                        'longitude': null,
                      });
                      _sortLogsChronologically();
                    });
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

  @override
  Widget build(BuildContext context) {
    final Duration elapsed = _getTimeSinceLastExposure();
    final int baselineAge = _calculateClinicalLungAge(TestContext.standardBaseline);
    final int exposureAge = _calculateClinicalLungAge(TestContext.relapseSlip);

    return Scaffold(
      appBar: AppBar(
        title: const Text("AirEngine Telemetry"),
        backgroundColor: Colors.teal.shade100,
        leading: _currentStatus != BreathRecorderState.idle
            ? IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.black87),
                tooltip: "Discard current recording",
                onPressed: () => _showDiscardConfirmationDialog(context),
              )
            : null,
        actions: [
          IconButton(icon: const Icon(Icons.share), tooltip: "Secure Data Export", onPressed: _showExportFilterBottomSheet),
          IconButton(
            icon: const Icon(Icons.edit_calendar),
            tooltip: "Log Forgotten Smoke",
            onPressed: _handleBackdatedExposureLogging,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _showResetConfirmationDialog)
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
                                const Text("SMOKE-FREE STREAK DURATION", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                                Text("${elapsed.inHours}h ${elapsed.inMinutes % 60}m ${elapsed.inSeconds % 60}s", style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
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
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildMetricsUnit("Stable Lung Age", baselineAge, Colors.tealAccent),
                                _buildMetricsUnit("Post-Smoke Age", exposureAge, Colors.redAccent),
                              ],
                            ),
                          ),

                          MilestoneProgressCard(
                            quitTimestamp: DateTime.now().subtract(elapsed),
                          ),

                          _buildTrendLineChartVisualization(),

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
                          onTap: (index) => setState(() {}),
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

  Widget _buildMetricsUnit(String label, int value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 2),
        Text("$value yrs", style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildCravingCountdownWidget() {
    int min = _cravingSecondsLeft ~/ 60;
    int sec = _cravingSecondsLeft % 60;

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
            label: const Text("I Smoked", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
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

  Widget _buildTrendLineChartVisualization() {
    final List<Map<String, dynamic>> rawBaselineLogs = _historicalLogs
        .where((log) => log['context'] == TestContext.standardBaseline && (log['duration'] as Duration).inMilliseconds > 0)
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
            "No baseline capacity logs available for charting yet.",
            style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    final DateTime oldestDate = rawBaselineLogs.first['timestamp'] as DateTime;
    final int totalSpanDays = DateTime.now().difference(oldestDate).inDays;

    List<Map<String, dynamic>> chartDataPoints = [];
    String timeGroupingLabel = "Daily View";

    if (totalSpanDays > 180) {
      timeGroupingLabel = "Monthly Averages";
      Map<String, List<double>> monthlyBuckets = {};
      Map<String, DateTime> monthlyRepresentativeDate = {};

      for (var log in rawBaselineLogs) {
        DateTime dt = log['timestamp'] as DateTime;
        String key = "${dt.year}-${dt.month.toString().padLeft(2, '0')}";
        double sec = (log['duration'] as Duration).inMilliseconds / 1000.0;

        monthlyBuckets.putIfAbsent(key, () => []).add(sec);
        monthlyRepresentativeDate[key] = DateTime(dt.year, dt.month, 1);
      }

      monthlyBuckets.forEach((key, values) {
        double avgSec = values.reduce((a, b) => a + b) / values.length;
        chartDataPoints.add({
          'timestamp': monthlyRepresentativeDate[key],
          'durationSec': avgSec,
        });
      });
    } else if (totalSpanDays > 45) {
      timeGroupingLabel = "Weekly Averages";
      Map<int, List<double>> weeklyBuckets = {};
      Map<int, DateTime> weeklyRepresentativeDate = {};

      for (var log in rawBaselineLogs) {
        DateTime dt = log['timestamp'] as DateTime;
        int weekKey = dt.year * 100 + (dt.difference(DateTime(dt.year, 1, 1)).inDays / 7).floor();
        double sec = (log['duration'] as Duration).inMilliseconds / 1000.0;

        weeklyBuckets.putIfAbsent(weekKey, () => []).add(sec);
        weeklyRepresentativeDate.putIfAbsent(weekKey, () => dt);
      }

      weeklyBuckets.forEach((key, values) {
        double avgSec = values.reduce((a, b) => a + b) / values.length;
        chartDataPoints.add({
          'timestamp': weeklyRepresentativeDate[key],
          'durationSec': avgSec,
        });
      });
    } else {
      timeGroupingLabel = "High-Fidelity Log";
      for (var log in rawBaselineLogs) {
        double sec = (log['duration'] as Duration).inMilliseconds / 1000.0;
        chartDataPoints.add({
          'timestamp': log['timestamp'],
          'durationSec': sec,
        });
      }
    }

    chartDataPoints.sort((a, b) => (a['timestamp'] as DateTime).compareTo(b['timestamp'] as DateTime));

    double minDurationSec = double.infinity;
    double maxDurationSec = 0;
    
    for (var point in chartDataPoints) {
      double sec = point['durationSec'] as double;
      if (sec < minDurationSec) minDurationSec = sec;
      if (sec > maxDurationSec) maxDurationSec = sec;
    }

    if (minDurationSec == double.infinity) minDurationSec = 0;

    double yAxisMin = max(0, minDurationSec - 2.0);
    double yAxisMax = maxDurationSec + 3.0;

    List<FlSpot> spots = [];
    for (int i = 0; i < chartDataPoints.length; i++) {
      spots.add(FlSpot(i.toDouble(), chartDataPoints[i]['durationSec'] as double));
    }

    return Container(
      height: 235,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
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
                minY: yAxisMin,
                maxY: yAxisMax,
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
                      interval: max(1, (spots.length / 4).floor().toDouble()),
                      getTitlesWidget: (value, meta) {
                        int index = value.toInt();
                        if (index < 0 || index >= chartDataPoints.length) return const SizedBox.shrink();
                        DateTime dt = chartDataPoints[index]['timestamp'] as DateTime;
                        
                        String labelText = totalSpanDays > 180 
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
        ],
      ),
    );
  }

  Widget _buildTimeframeFilteredList(int tabIndex) {
    final now = DateTime.now();
    List<Map<String, dynamic>> filtered = _historicalLogs.where((log) {
      final DateTime time = log['timestamp'] as DateTime;
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
        final DateTime dt = item['timestamp'] as DateTime;
        final double dur = (item['duration'] as Duration).inMilliseconds / 1000.0;
        final TestContext ctx = item['context'] as TestContext;

        IconData icon = Icons.air_rounded; 
        Color iconColor = Colors.teal.shade700;
        Color bgColor = Colors.teal.shade50;
        String title = "Standard Exhale";

        if (ctx == TestContext.postExposure) {
          icon = Icons.masks_rounded; 
          iconColor = Colors.amber.shade800;
          bgColor = Colors.amber.shade50;
          title = "Post Exposure";
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
              padding: const EdgeInsets.only(bottom: 12.0),
              child: LinearProgressIndicator(
                value: _liveVolumeLevel,
                backgroundColor: Colors.grey.shade200,
                color: isRecording ? Colors.teal : Colors.orange,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
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
                    : (isCalibrating ? "Calibrating Microphone..." : "Begin Exhale Capacity Test"),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              onPressed: () {
                if (isRecording) {
                  _audioService.stopRecording();
                } else if (_currentStatus == BreathRecorderState.idle) {
                  _audioService.startRecording();
                }
              },
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
    return false;
  }
}