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

enum TestContext { standardBaseline, postExposure, cravingThreat }

class BreathTestScreen extends StatefulWidget {
  const BreathTestScreen({super.key});

  @override
  State<BreathTestScreen> createState() => _BreathTestScreenState();
}

class _BreathTestScreenState extends State<BreathTestScreen> with SingleTickerProviderStateMixin {
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
      setState(() { _liveVolumeLevel = normalizedDb; });
    });

    _resetGlobalTimelineTicker();
    _loadPersistedDatabase(); 
  }

  /// 🕒 Launches backdated selection sheets to record forgotten exposure events accurately
  Future<void> _handleBackdatedExposureLogging() async {
    // 1. Pick the historical calendar date
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      helpText: "SELECT RELAPSE DATE",
    );

    if (pickedDate == null) return;

    // 2. Pick the exact clock time it occurred
    if (!mounted) return;
    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: "SELECT RELAPSE TIME",
    );

    if (pickedTime == null) return;

    // 3. Merge calendar date with clock time parameters
    final DateTime targetTimestamp = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    // 4. Commit the retroactively dated record directly to the database array
    setState(() {
      _historicalLogs.insert(0, {
        'path': 'RETROACTIVE_BACKDATED_LOG',
        'duration': Duration.zero,
        'context': TestContext.postExposure, // 🚨 Correctly resets streak timeline back to this historical point
        'timestamp': targetTimestamp,
        'isManual': true,
        'latitude': null,
        'longitude': null,
      });

      _sortLogsChronologically(); // Instantly reshuffles timeline so charts stay perfectly aligned
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
    setState(() {
      _historicalLogs.clear();
      if (savedData.isNotEmpty) {
        for (var log in savedData) {
          final contextStr = log['context'].toString();
          TestContext parsedContext = TestContext.standardBaseline;
          
          if (contextStr.contains("postExposure")) {
            parsedContext = TestContext.postExposure;
          } else if (contextStr.contains("cravingThreat")) {
            parsedContext = TestContext.cravingThreat;
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
            _lastShieldEndTime = DateTime.now(); // 💾 Mark completion for the cool-down anchor
            _showCravingCompleteAlert();
          }
        }
      });
    });
  }

  void _handleStateTransitions(BreathRecorderState newState) {
    if (newState == BreathRecorderState.recording && _currentStatus != BreathRecorderState.recording) {
      HapticFeedback.mediumImpact();
    } else if (newState == BreathRecorderState.idle) {
      setState(() { _liveVolumeLevel = 0.0; });
    }
    setState(() { _currentStatus = newState; });
  }

  int _calculateClinicalLungAge(TestContext focusContext) {
    final filtered = _historicalLogs.where((log) => log['context'] == focusContext && (log['duration'] as Duration).inMilliseconds > 0).take(3).toList();
    
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
    DateTime? lastPostExposure;
    for (var log in _historicalLogs) {
      if (log['context'] == TestContext.postExposure) {
        if (lastPostExposure == null || (log['timestamp'] as DateTime).isAfter(lastPostExposure)) {
          lastPostExposure = log['timestamp'];
        }
      }
    }
    if (lastPostExposure == null) {
      return _historicalLogs.isNotEmpty ? DateTime.now().difference(_historicalLogs.last['timestamp']) : Duration.zero;
    }
    return DateTime.now().difference(lastPostExposure);
  }

  List<Map<String, dynamic>> _getFilteredHistoryByTimeframe(int tabIndex) {
    final now = DateTime.now();
    return _historicalLogs.where((log) {
      final timestamp = log['timestamp'] as DateTime;
      final difference = now.difference(timestamp);

      switch (tabIndex) {
        case 0: return difference.inDays <= 1; 
        case 1: return difference.inDays <= 7; 
        case 2: return difference.inDays <= 30; 
        case 3: return difference.inDays <= 365; 
        default: return true;
      }
    }).toList();
  }

 Future<void> _exportBiometricDataSecurely({DateTime? startDate, DateTime? endDate}) async {
    final StringBuffer csvBuffer = StringBuffer();
    csvBuffer.writeln("Timestamp_ISO8601,Medical_Context,Exhale_Duration_Sec,Latitude,Longitude,Data_Ingestion_Type");
    
    // Filter the records chronologically based on bounds if provided
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
      if (log['context'] == TestContext.postExposure) contextStr = "CravingRelapseSlip";
      if (log['context'] == TestContext.cravingThreat) contextStr = "CravingDeflectedThreat";

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

      // 🗺️ 1. LOOK UP SCREEN COORDINATES (Crucial for iPad stability)
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Rect? sharePositionOrigin = box != null 
          ? box.localToGlobal(Offset.zero) & box.size 
          : null;
      
      // 🔄 2. PASS THE ORIGIN ANCHOR TO THE SHARE CALL
      await Share.shareXFiles(
        [xFile], 
        subject: 'AirEngine Biometric Telemetry Report',
        sharePositionOrigin: sharePositionOrigin, // 👈 Fixes the PlatformException
      );
      
      // 🕒 3. DELAY PURGE SLIGHTLY SO iOS CAN HAND OFF FILE READ HANDLES
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
                const Text(
                  "Export Telemetry Report", 
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)
                ),
                const SizedBox(height: 4),
                Text("Select chronological parameters for CSV data payload generation.", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.date_range_rounded, color: Colors.teal),
                  title: const Text("Past 30 Days", style: TextStyle(fontSize: 14)),
                  onTap: () { // 🔄 Changed from onPressed
                    Navigator.pop(context);
                    _exportBiometricDataSecurely(startDate: now.subtract(const Duration(days: 30)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today_rounded, color: Colors.teal),
                  title: const Text("Year to Date (Whole Year)", style: TextStyle(fontSize: 14)),
                  onTap: () { // 🔄 Changed from onPressed
                    Navigator.pop(context);
                    _exportBiometricDataSecurely(startDate: DateTime(now.year, 1, 1));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded, color: Colors.teal),
                  title: const Text("All-Time Historical Ledger", style: TextStyle(fontSize: 14)),
                  onTap: () { // 🔄 Changed from onPressed
                    Navigator.pop(context);
                    _exportBiometricDataSecurely(); 
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.tune_rounded, color: Colors.orange),
                  title: const Text("Custom Date Range...", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  onTap: () async { // 🔄 Changed from onPressed
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
    final now = DateTime.now();

    // 🕒 Clinical Cool-down validation checkpoint barrier
    if (_lastShieldEndTime != null && now.difference(_lastShieldEndTime!).inMinutes < 15) {
      final int minutesLeft = 15 - now.difference(_lastShieldEndTime!).inMinutes;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Urge managed successfully! Try an Evaluation test to check your performance right now ($minutesLeft min until shield re-arms)."),
            backgroundColor: Colors.teal.shade700,
          ),
        );
      }
      return;
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
    setState(() {
      _isCravingModeActive = false;
      _cravingSecondsLeft = 0;
      _lastShieldEndTime = null; // Wipe cool-down since they relapsed

      _historicalLogs.removeWhere((log) => log['path'] == 'CRAVING_TRIGGER_MARKER' && log['duration'] == Duration.zero);

      _historicalLogs.insert(0, {
        'path': 'USER_DECLARED_SLIP_UP',
        'duration': Duration.zero,
        'context': TestContext.postExposure, 
        'timestamp': DateTime.now(),
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
          content: Text("Streak reset. Slip-ups happen—every breath moving forward is an opportunity to rebuild."),
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
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Breath Captured"),
              content: Text("Sustained Exhalation: ${(result.duration.inMilliseconds / 1000).toStringAsFixed(2)}s"),
              actions: [
                DropdownButton<TestContext>(
                  value: selectedContext,
                  items: const [
                    DropdownMenuItem(value: TestContext.standardBaseline, child: Text("Standard Baseline")),
                    DropdownMenuItem(value: TestContext.postExposure, child: Text("Post-Exposure")),
                  ],
                  onChanged: (val) { if (val != null) setDialogState(() => selectedContext = val); },
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
                    });
                    await _commitStateToDisk(); 
                    if (context.mounted) Navigator.pop(context);
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
    final int exposureAge = _calculateClinicalLungAge(TestContext.postExposure);

    return Scaffold(
      appBar: AppBar(
        title: const Text("AirEngine Telemetry"),
        backgroundColor: Colors.teal.shade100,
        actions: [
          IconButton(icon: const Icon(Icons.share), tooltip: "Secure Data Export", onPressed: _showExportFilterBottomSheet),

          // ➕ ADD THIS ACTION BUTTON HERE:
          IconButton(
            icon: const Icon(Icons.edit_calendar), 
            tooltip: "Log Forgotten Smoke", 
            onPressed: _handleBackdatedExposureLogging,
          ),

          IconButton(icon: const Icon(Icons.refresh), onPressed: _showResetConfirmationDialog)
        ],
      ),
      body: Column(
        children: [
          if (_isCravingModeActive) _buildCravingCountdownWidget(),
          
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

          _buildMilestoneTrackSection(elapsed),

          SizedBox(
            height: 180, 
            child: _buildTrendLineChartVisualization(),
          ),

          const Divider(height: 1),

          TabBar(
            controller: _timeframeTabController,
            labelColor: Colors.teal.shade900,
            indicatorColor: Colors.teal.shade700,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            tabs: const [
              Tab(text: "Today"),
              Tab(text: "7 Days"),
              Tab(text: "30 Days"),
              Tab(text: "All Logs")
            ],
            onTap: (index) => setState(() {}),
          ),

          Expanded(
            child: TabBarView(
              controller: _timeframeTabController,
              children: [
                _buildTimeframeFilteredList(0), // Today Only
                _buildTimeframeFilteredList(1), // Past 7 Days
                _buildTimeframeFilteredList(2), // Past 30 Days
                _buildTimeframeFilteredList(3), // All History
              ],
            ),
          ),

          _buildSensingBottomControl(),
        ],
      ),
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
    List<FlSpot> baselineSpots = [];
    List<VerticalLine> behaviorLines = [];
    
    //  New Way: Take only the last 15 total logs to keep the UI clean
    final chronLogs = _historicalLogs.take(15).toList().reversed.toList();
    
    int breathTestIndex = 0;

    for (int i = 0; i < chronLogs.length; i++) {
      final log = chronLogs[i];

      if (log['context'] == TestContext.standardBaseline) {
        double durationSec = (log['duration'] as Duration).inMilliseconds / 1000.0;
        if (durationSec > 0) {
          // Map this spot sequentially using our custom counter
          baselineSpots.add(FlSpot(breathTestIndex.toDouble(), durationSec));
          breathTestIndex++;
        }
      } 
      // If a slip-up or craving occurs, attach it to the current breath test neighborhood
      else if (log['context'] == TestContext.postExposure) {
        behaviorLines.add(
          VerticalLine(
            x: breathTestIndex > 0 ? (breathTestIndex - 1).toDouble() : 0.0,
            color: Colors.red.withOpacity(0.6),
            strokeWidth: 2,
            dashArray: [4, 4],
            label: VerticalLineLabel(
              show: true,
              // 🔄 Pushes alignment inward to the left of the line so it stays safely inside the grid area
              alignment: Alignment.topLeft, 
              style: TextStyle(
                color: Colors.red.shade900, 
                fontSize: 9, 
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.white.withOpacity(0.8), // Small clear background block for legibility
              ),
              labelResolver: (line) => " SLIP",
            ),
          ),
        );
      } 
      else if (log['path'] == 'CRAVING_TRIGGER_MARKER') {
        behaviorLines.add(
          VerticalLine(
            x: breathTestIndex > 0 ? (breathTestIndex - 1).toDouble() : 0.0,
            color: Colors.orange.withOpacity(0.4),
            strokeWidth: 1.5,
            dashArray: [2, 2],
          ),
        );
      }
    }

    if (baselineSpots.isEmpty) {
      return const Center(child: Text("Perform breath tests to generate a trend graph."));
    }

    // Dynamic ceiling calculation
    double calculatedMaxY = 15.0;
    for (var spot in baselineSpots) {
      if (spot.y > calculatedMaxY) {
        calculatedMaxY = spot.y + 2.0; 
      }
    }

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          const Text(
            "Pulmonary Capacity Progression Trend (Seconds)", 
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,   
                maxY: calculatedMaxY, 
                
                // 🔓 Stop clipping text labels at the extreme border edges of the canvas
                clipData: const FlClipData.none(),
                
                gridData: const FlGridData(show: true),
                
                // 📊 Bind our safely indexed behavioral line annotations
                extraLinesData: ExtraLinesData(verticalLines: behaviorLines),

                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: 2.0, 
                      getTitlesWidget: (value, meta) {
                        return SideTitleWidget(
                          axisSide: meta.axisSide,
                          child: Text(
                            value.toStringAsFixed(0),
                            style: const TextStyle(fontSize: 10, color: Colors.black54),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      // 🔒 Restricts steps strictly to integers (#1, #2, #3...)
                      interval: 1.0, 
                      getTitlesWidget: (value, meta) {
                        // Prevent drawing fractional index ticks like 0.5 entirely
                        if (value % 1 != 0 || value < 0 || value >= breathTestIndex) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          axisSide: meta.axisSide,
                          child: Text(
                            "#${value.toInt() + 1}",
                            style: const TextStyle(fontSize: 9, color: Colors.black54),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: baselineSpots,
                    isCurved: true,
                    color: Colors.teal,
                    barWidth: 3,
                    preventCurveOverShooting: true, 
                    belowBarData: BarAreaData(show: true, color: Colors.teal.withOpacity(0.1)),
                  )
                ]
              )
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMilestoneTrackSection(Duration elapsed) {
    bool metricsActive = _historicalLogs.isNotEmpty;
    bool min20 = metricsActive && elapsed.inMinutes >= 20;
    bool hr8 = metricsActive && elapsed.inHours >= 8;
    bool hr48 = metricsActive && elapsed.inHours >= 48;
    bool hr72 = metricsActive && elapsed.inHours >= 72;

    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey.shade50,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildMilestoneCard("20 Min", "HR & BP Normalize", min20, Icons.favorite),
            const SizedBox(width: 6),
            _buildMilestoneCard("8 Hours", "CO Drops by 50%", hr8, Icons.bloodtype),
            const SizedBox(width: 6),
            _buildMilestoneCard("48 Hours", "Nerve Endings Regrow", hr48, Icons.hearing),
            const SizedBox(width: 6),
            _buildMilestoneCard("72 Hours", "Bronchioles Relax", hr72, Icons.air),
          ],
        ),
      ),
    );
  }

  Widget _buildMilestoneCard(String timeframe, String desc, bool isUnlocked, IconData icon) {
    return Container(
      width: 130,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isUnlocked ? Colors.teal.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isUnlocked ? Colors.teal.shade300 : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(timeframe, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isUnlocked ? Colors.teal.shade900 : Colors.black87)),
              Icon(isUnlocked ? Icons.check_circle : icon, size: 12, color: isUnlocked ? Colors.teal : Colors.grey),
            ],
          ),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(fontSize: 9, color: Colors.black54), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildTimeframeFilteredList(int activeTimeframeIndex) {
    final DateTime now = DateTime.now();
    DateTime thresholdDate;

   switch (activeTimeframeIndex) {
      case 0: // Today Only (Since Midnight)
        thresholdDate = DateTime(now.year, now.month, now.day);
        break;
      case 1: // Past 7 Days
        thresholdDate = now.subtract(const Duration(days: 7));
        break;
      case 2: // Past 30 Days
        thresholdDate = now.subtract(const Duration(days: 30));
        break;
      case 3: // All History
      default:
        thresholdDate = DateTime(2000); 
    }

    final List<Map<String, dynamic>> filteredLogs = _historicalLogs.where((log) {
      final DateTime logTime = log['timestamp'] as DateTime;
      return logTime.isAfter(thresholdDate);
    }).toList();

    if (filteredLogs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.layers_clear_outlined, size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                "No logs recorded within this period.",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
        // 🔓 CHANGE THESE TWO LINES:
        shrinkWrap: false,                           // Allows the list to expand naturally
        physics: const AlwaysScrollableScrollPhysics(), // Forces touch scrolling to turn back on
        
        itemCount: filteredLogs.length,
        itemBuilder: (context, index) {
        final log = filteredLogs[index];
        final Duration duration = log['duration'] as Duration;
        final DateTime timestamp = log['timestamp'] as DateTime;
        
        final bool isPureRelapseMarker = 
            log['context'] == TestContext.postExposure && duration == Duration.zero;

        final String formattedDate = 
            "${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} "
            "${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}";

        // 🚬 Determine the correct icon for the leading slot
        IconData leadingIcon;
        Color iconColor;
        Color bgColor;

        if (isPureRelapseMarker) {
          leadingIcon = Icons.local_fire_department_rounded; // 🔥 Pure Behavioral Slip
          iconColor = Colors.red;
          bgColor = Colors.red.withOpacity(0.1);
        } else if (log['context'] == TestContext.postExposure) {
          leadingIcon = Icons.smoking_rooms_rounded;         // 🚬 Post-Exposure Breath Test
          iconColor = Colors.orange;
          bgColor = Colors.orange.withOpacity(0.1);
        } else {
          leadingIcon = Icons.air_rounded;                   // 🫁 Standard Baseline Test
          iconColor = Colors.teal;
          bgColor = Colors.teal.withOpacity(0.1);
        }

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Colors.grey.shade200, width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            
            // 🎨 Updated Avatar utilizing our conditional icon mapping rules above
            leading: CircleAvatar(
              backgroundColor: bgColor,
              child: Icon(
                leadingIcon,
                color: iconColor,
                size: 20,
              ),
            ),

            title: Text(
              isPureRelapseMarker ? "Relapse Event Tracked" : "Pulmonary Capacity Test",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87),
            ),
            subtitle: Text(
              formattedDate,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            trailing: isPureRelapseMarker
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      "SLIP",
                      style: TextStyle(
                        color: Colors.red.shade900, 
                        fontWeight: FontWeight.bold, 
                        fontSize: 10,
                        letterSpacing: 0.5,
                      ),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        (duration.inMilliseconds / 1000.0).toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: log['context'] == TestContext.postExposure ? Colors.orange.shade800 : Colors.teal.shade800,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        "s",
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildSensingBottomControl() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _currentStatus == BreathRecorderState.recording ? Colors.green.shade100 : Colors.grey.shade100,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_currentStatus != BreathRecorderState.idle)
              LinearProgressIndicator(value: _liveVolumeLevel, minHeight: 8),
            const SizedBox(height: 8),
            if (_currentStatus == BreathRecorderState.idle)
              ElevatedButton.icon(
                // 🔒 UI Freeze: Explicitly set onPressed to null to drop tap interaction patterns entirely
                onPressed: _isCravingModeActive 
                    ? null 
                    : () => _audioService.startMonitoring(),
                icon: const Icon(Icons.mic),
                label: Text(_isCravingModeActive 
                    ? "Shield Active (Delaying Urge...)" 
                    : "Execute Breath Capacity Evaluation"),
              )
            else
              Text(_currentStatus == BreathRecorderState.recording ? "SUSTAIN CONSTANT AIRFLOW PRESSURE..." : "Configuring atmospheric sensor limits..."),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsUnit(String label, int value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        Text("Age $value", style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
      ],
    );
  }

  @override
  void dispose() {
    _timeframeTabController.dispose();
    _tickerTimer?.cancel();
    _volumeSubscription?.cancel();
    _audioService.dispose();
    super.dispose();
  }
}