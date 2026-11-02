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

  final void Function(BreathRecorderState)? onStateChanged;
  final void Function(AudioTestResult)? onRecordingComplete;

  /// Called when a recording ends WITHOUT a valid result
  /// (no breath detected, too short, etc.) so the UI can tell the user why.
  final void Function(String reason)? onTestInvalid;

  Timer? _amplitudeTimer;
  String? _currentFilePath;

  final List<double> _amplitudeSamples = [];
  double _baselineNoiseFloor = -50.0;
  bool _isCalibrated = false;

  // Recording state
  DateTime? _recordingStartTime; // when recording began (for idle timeout)
  DateTime? _breathStartTime;    // first loud tick
  DateTime? _lastLoudTime;       // last tick still above the "sustained" level
  bool _tickBusy = false;        // prevents overlapping async ticks
  bool _finishing = false;       // prevents double stop/cancel

  bool get hasBreathStarted => _breathStartTime != null;
  bool get isCalibrated => _isCalibrated;

  // Configuration
  static const Duration _tickInterval = Duration(milliseconds: 50);
  static const Duration _trailingSilence = Duration(milliseconds: 700);
  static const Duration _idleStartupTimeout = Duration(seconds: 5);
  static const Duration _minValidExhale = Duration(seconds: 1);
  static const double _strictBreathThreshold = 0.45;
  static const double _sustainThreshold = 0.45 * 0.4;

  BreathAudioService({
    this.onStateChanged,
    this.onRecordingComplete,
    this.onTestInvalid,
  });

  Future<bool> hasPermission() async {
    return await _audioRecorder.hasPermission();
  }

  /// Calibrates only once per app session (call [recalibrate] to force).
  Future<void> ensureCalibrated() async {
    if (_isCalibrated) return;
    await startCalibration();
  }

  void recalibrate() => _isCalibrated = false;

  Future<void> startCalibration({
    Duration duration = const Duration(seconds: 2),
  }) async {
    if (_state != BreathRecorderState.idle) return;

    if (!await hasPermission()) {
      throw Exception('Microphone permission not granted.');
    }

    _updateState(BreathRecorderState.calibrating);

    final tempDir = await getTemporaryDirectory();
    final calibPath =
        p.join(tempDir.path, 'calib_${DateTime.now().millisecondsSinceEpoch}.m4a');

    final List<double> calibSamples = [];
    Timer? calibTimer;
    bool sampling = false;

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: calibPath,
      );

      calibTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
        if (sampling) return;
        sampling = true;
        try {
          final amp = await _audioRecorder.getAmplitude();
          // Ignore the "no data yet" floor values (-160 dB)
          if (amp.current > -100) calibSamples.add(amp.current);
        } catch (_) {} finally {
          sampling = false;
        }
      });

      await Future.delayed(duration);
    } finally {
      calibTimer?.cancel();
      try {
        await _audioRecorder.stop();
      } catch (_) {}
      await _deleteFile(calibPath);
    }

    if (calibSamples.isNotEmpty) {
      final avg = calibSamples.reduce((a, b) => a + b) / calibSamples.length;
      // Keep the floor in a sane range so a very quiet/very noisy room can't break normalization.
      _baselineNoiseFloor = avg.clamp(-70.0, -25.0);
      _isCalibrated = true;
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
    _breathStartTime = null;
    _lastLoudTime = null;
    _tickBusy = false;
    _finishing = false;

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: _currentFilePath!,
    );

    _updateState(BreathRecorderState.recording);

    _amplitudeTimer = Timer.periodic(_tickInterval, (_) async {
      if (_state != BreathRecorderState.recording || _tickBusy || _finishing) return;
      _tickBusy = true;

      try {
        final amp = await _audioRecorder.getAmplitude();
        if (_state != BreathRecorderState.recording || _finishing) return;

        final now = DateTime.now();
        final normalized = _normalizeAmplitude(amp.current);

        _amplitudeSamples.add(normalized);
        if (!_volumeController.isClosed) _volumeController.add(normalized);

        if (_breathStartTime == null) {
          // Wait for a real blow; give up after the idle timeout (wall-clock based).
          if (normalized >= _strictBreathThreshold) {
            _breathStartTime = now;
            _lastLoudTime = now;
          } else if (now.difference(_recordingStartTime!) >= _idleStartupTimeout) {
            await _abort('No breath detected. Blow steadily toward the microphone and try again.');
          }
        } else {
          if (normalized >= _sustainThreshold) {
            _lastLoudTime = now;
          } else if (now.difference(_lastLoudTime!) >= _trailingSilence) {
            await stopRecording();
          }
        }
      } catch (_) {
        // Ignore a single failed amplitude read.
      } finally {
        _tickBusy = false;
      }
    });
  }

  Future<AudioTestResult?> stopRecording() async {
    if (_state != BreathRecorderState.recording || _finishing) return null;
    _finishing = true;

    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;

    String? path;
    try {
      path = await _audioRecorder.stop();
    } catch (_) {}

    final started = _breathStartTime;
    final lastLoud = _lastLoudTime;
    final samples = List<double>.from(_amplitudeSamples);

    _updateState(BreathRecorderState.idle);
    _finishing = false;

    // Exhale length = first loud tick -> last loud tick (trailing silence is NOT counted).
    final Duration duration = (started != null && lastLoud != null)
        ? lastLoud.difference(started)
        : Duration.zero;

    if (path == null || samples.isEmpty || started == null) {
      await _deleteFile(path ?? _currentFilePath);
      onTestInvalid?.call('No breath detected. Please try again.');
      return null;
    }

    if (duration < _minValidExhale) {
      await _deleteFile(path);
      onTestInvalid?.call('Exhale was too short to measure. Blow steadily for at least a second.');
      return null;
    }

    final maxAmp = samples.reduce((a, b) => a > b ? a : b);
    final avgAmp = samples.reduce((a, b) => a + b) / samples.length;

    final result = AudioTestResult(
      filePath: path,
      duration: duration,
      maxAmplitude: maxAmp,
      averageAmplitude: avgAmp,
    );

    onRecordingComplete?.call(result);
    return result;
  }

  /// User-initiated discard (no message shown).
  Future<void> cancelRecording() => _abort(null);

  Future<void> _abort(String? reason) async {
    if (_state != BreathRecorderState.recording || _finishing) return;
    _finishing = true;

    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;

    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
    } catch (_) {}

    await _deleteFile(_currentFilePath);
    _amplitudeSamples.clear();
    _breathStartTime = null;
    _lastLoudTime = null;

    _updateState(BreathRecorderState.idle);
    _finishing = false;

    if (reason != null) onTestInvalid?.call(reason);
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  double _normalizeAmplitude(double db) {
    if (db.isNaN || db < _baselineNoiseFloor) return 0.0;
    if (db >= 0.0) return 1.0;

    final range = 0.0 - _baselineNoiseFloor;
    if (range <= 0) return 0.0;

    return ((db - _baselineNoiseFloor) / range).clamp(0.0, 1.0);
  }

  void _updateState(BreathRecorderState newState) {
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(_state);
    onStateChanged?.call(_state);
  }

  Future<void> dispose() async {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
    } catch (_) {}
    await _deleteFile(_currentFilePath);
    await _audioRecorder.dispose();
    await _stateController.close();
    await _volumeController.close();
  }
}