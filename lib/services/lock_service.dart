// lib/services/lock_service.dart
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Thin wrapper around the device's fingerprint / face / passcode prompt.
class LockService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// True when the phone has a screen lock or biometrics the app can use.
  Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('LockService: isSupported failed: $e');
      return false;
    }
  }

  /// Shows the system prompt. Falls back to the device PIN / pattern / passcode.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
    } catch (e) {
      debugPrint('LockService: authenticate failed: $e');
      return false;
    }
  }
}
