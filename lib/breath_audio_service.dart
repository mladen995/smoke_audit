import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

enum BreathRecorderState {
  idle,
  calibrating,
  recording,
}

class AudioTestResult {
  final String filePath;
  final Duration duration;
  final double maxAmplitude;
  final double averageAmplitude;

  const AudioTestResult({
    required this.filePath,
    required this.duration,
    required this.maxAmplitude,
    required this.averageAmplitude,
  });
}

class BreathAudioService {
  final AudioRecorder _audioRecorder = AudioRecorder();

  BreathRecorderState _state = BreathRecorderState.idle;
  BreathRecorderState get state => _state;

  final StreamController<BreathRecorderState> _stateController =
      StreamController<BreathRecorderState>.broadcast();
  Stream<BreathRecorderState> get stateStream => _stateController.stream;

  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();
  Stream<double> get volumeStream => _volumeController.stream;

  final Function(BreathRecorderState)? onStateChanged;
  final Function(AudioTestResult)? onRecordingComplete;

  Timer? _amplitudeTimer;
  DateTime? _recordingStartTime;
  String? _currentFilePath;

  final List<double> _amplitudeSamples = [];
  double _baselineNoiseFloor = -50.0;

  // 🌬️ Robust Exhalation & Timeout State Variables
  bool _hasBreathStarted = false;
  int _silenceTickCount = 0;
  int _recordingTickCounter = 0;
  
  // Configuration Constants
  static const int _maxSilenceTicks = 14;       // ~0.7s of trailing silence to complete test
  static const int _maxIdleStartupTicks = 100;  // 5 seconds (100 ticks * 50ms) before auto-canceling if no breath detected
  static const double _strictBreathThreshold = 0.45; // High threshold to completely ignore background room noise/speech

  BreathAudioService({
    this.onStateChanged,
    this.onRecordingComplete,
  });

  Future<bool> hasPermission() async {
    return await _audioRecorder.hasPermission();
  }

  Future<void> startCalibration({
    Duration duration = const Duration(seconds: 2),
  }) async {
    if (_state != BreathRecorderState.idle) return;

    if (!await hasPermission()) {
      throw Exception('Microphone permission not granted.');
    }

    _updateState(BreathRecorderState.calibrating);

    final tempDir = await getTemporaryDirectory();
    final calibPath = p.join(tempDir.path, 'calib_${DateTime.now().millisecondsSinceEpoch}.m4a');

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: calibPath,
    );

    List<double> calibSamples = [];
    final calibTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final amp = await _audioRecorder.getAmplitude();
      calibSamples.add(amp.current);
    });

    await Future.delayed(duration);

    calibTimer.cancel();
    await _audioRecorder.stop();

    final file = File(calibPath);
    if (await file.exists()) {
      await file.delete();
    }

    if (calibSamples.isNotEmpty) {
      _baselineNoiseFloor = calibSamples.reduce((a, b) => a + b) / calibSamples.length;
    }

    _updateState(BreathRecorderState.idle);
  }

  Future<void> startRecording() async {
    if (_state != BreathRecorderState.idle) return;

    if (!await hasPermission()) {
      throw Exception('Microphone permission not granted.');
    }

    final tempDir = await getTemporaryDirectory();
    _currentFilePath = p.join(
      tempDir.path,
      'breath_test_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    _amplitudeSamples.clear();
    _recordingStartTime = DateTime.now();
    
    // Reset state counters
    _hasBreathStarted = false;
    _silenceTickCount = 0;
    _recordingTickCounter = 0;

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: _currentFilePath!,
    );

    _updateState(BreathRecorderState.recording);

    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      if (_state != BreathRecorderState.recording) return;

      _recordingTickCounter++;
      final amp = await _audioRecorder.getAmplitude();
      final normalized = _normalizeAmplitude(amp.current);

      _amplitudeSamples.add(normalized);
      _volumeController.add(normalized);

      if (!_hasBreathStarted) {
        // ⏳ 5-Second Startup Timeout Rule: If user doesn't blow within 5s, cancel completely
        if (_recordingTickCounter >= _maxIdleStartupTicks) {
          await cancelRecording();
          return;
        }

        // 🔍 Check if the sound crosses the high threshold required for a direct breath blow
        if (normalized >= _strictBreathThreshold) {
          _hasBreathStarted = true;
          _recordingStartTime = DateTime.now(); // Reset start time to exact moment the breath actually begins
        }
      } else {
        // Breath has officially started; monitor for trailing silence to finish the test
        if (normalized < (_strictBreathThreshold * 0.4)) {
          _silenceTickCount++;
          if (_silenceTickCount >= _maxSilenceTicks) {
            await stopRecording();
          }
        } else {
          // Reset silence counter if they continue blowing forcefully
          _silenceTickCount = 0;
        }
      }
    });
  }

  Future<AudioTestResult?> stopRecording() async {
    if (_state != BreathRecorderState.recording) return null;

    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;

    final path = await _audioRecorder.stop();
    final endTime = DateTime.now();

    final duration = _recordingStartTime != null
        ? endTime.difference(_recordingStartTime!)
        : Duration.zero;

    _updateState(BreathRecorderState.idle);

    if (path == null || _amplitudeSamples.isEmpty || !_hasBreathStarted) {
      return null;
    }

    final maxAmp = _amplitudeSamples.reduce((a, b) => a > b ? a : b);
    final avgAmp = _amplitudeSamples.reduce((a, b) => a + b) / _amplitudeSamples.length;

    final result = AudioTestResult(
      filePath: path,
      duration: duration,
      maxAmplitude: maxAmp,
      averageAmplitude: avgAmp,
    );

    if (onRecordingComplete != null) {
      onRecordingComplete!(result);
    }

    return result;
  }

  Future<void> cancelRecording() async {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;

    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }

    if (_currentFilePath != null) {
      final file = File(_currentFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }

    _amplitudeSamples.clear();
    _updateState(BreathRecorderState.idle);
  }

  double _normalizeAmplitude(double db) {
    if (db < _baselineNoiseFloor) return 0.0;
    if (db >= 0.0) return 1.0;

    final range = 0.0 - _baselineNoiseFloor;
    if (range <= 0) return 0.0;

    return ((db - _baselineNoiseFloor) / range).clamp(0.0, 1.0);
  }

  void _updateState(BreathRecorderState newState) {
    _state = newState;
    _stateController.add(_state);
    if (onStateChanged != null) {
      onStateChanged!(_state);
    }
  }

  Future<void> dispose() async {
    _amplitudeTimer?.cancel();
    await _audioRecorder.dispose();
    await _stateController.close();
    await _volumeController.close();
  }
}