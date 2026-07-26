import 'dart:async';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

enum BreathRecorderState {
  idle,
  calibrating,
  recording,
}

class AudioTestResult {
  final String filePath;
  final Duration duration;

  AudioTestResult({required this.filePath, required this.duration});
}

class BreathAudioService {
  final void Function(BreathRecorderState) onStateChanged;
  final void Function(AudioTestResult) onRecordingComplete;

  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  
  BreathRecorderState _currentState = BreathRecorderState.idle;
  DateTime? _recordingStartTime;
  String? _currentFilePath;

  final StreamController<double> _volumeStreamController = StreamController<double>.broadcast();
  Stream<double> get volumeStream => _volumeStreamController.stream;

  final double _decibelThreshold = -32.0; 
  final int _requiredSustainedWindowMs = 250;

  BreathAudioService({
    required this.onStateChanged,
    required this.onRecordingComplete,
  });

  Future<void> startMonitoring() async {
    if (_currentState != BreathRecorderState.idle) return;

    try {
      if (!await _audioRecorder.hasPermission()) {
        _changeState(BreathRecorderState.idle);
        return;
      }

      _changeState(BreathRecorderState.calibrating);

      final directory = await getTemporaryDirectory();
      _currentFilePath = '${directory.path}/breath_test_${DateTime.now().millisecondsSinceEpoch}.m4a';

      final config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 64000,
        numChannels: 1,
      );

      await _audioRecorder.start(config, path: _currentFilePath!);

      _amplitudeSubscription = _audioRecorder.onAmplitudeChanged(const Duration(milliseconds: 50)).listen((amp) {
        _processAmplitudeEvent(amp);
      });

    } catch (e) {
      _cleanupSession();
      _changeState(BreathRecorderState.idle);
    }
  }

  void _processAmplitudeEvent(Amplitude amp) {
    double db = amp.current; 
    double normalizedLinearVolume = _convertDbToLinearRange(db);
    if (!_volumeStreamController.isClosed) {
      _volumeStreamController.add(normalizedLinearVolume);
    }

    if (_currentState == BreathRecorderState.calibrating) {
      if (db > _decibelThreshold) {
        _recordingStartTime = DateTime.now();
        _changeState(BreathRecorderState.recording);
      }
    } else if (_currentState == BreathRecorderState.recording) {
      if (db <= _decibelThreshold) {
        _finalizeAirflowTest();
      }
    }
  }

  double _convertDbToLinearRange(double db) {
    if (db < -60.0) return 0.0;
    if (db >= 0.0) return 1.0;
    return (db + 60.0) / 60.0;
  }

  Future<void> _finalizeAirflowTest() async {
    _amplitudeSubscription?.cancel();
    final String? savedPath = await _audioRecorder.stop();

    if (_recordingStartTime != null && savedPath != null) {
      final Duration finalDuration = DateTime.now().difference(_recordingStartTime!);

      if (finalDuration.inMilliseconds >= _requiredSustainedWindowMs) {
        onRecordingComplete(
          AudioTestResult(filePath: savedPath, duration: finalDuration),
        );
      }
    }

    _cleanupSession();
    _changeState(BreathRecorderState.idle);
  }

  Future<void> deleteCurrentRecording() async {
    try {
      if (_currentFilePath != null) {
        final file = File(_currentFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {}
  }

  void _cleanupSession() {
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _recordingStartTime = null;
  }

  void _changeState(BreathRecorderState state) {
    _currentState = state;
    onStateChanged(state);
  }

  void dispose() {
    _cleanupSession();
    _audioRecorder.dispose();
    _volumeStreamController.close();
  }
}