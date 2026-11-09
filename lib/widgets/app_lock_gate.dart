// lib/widgets/app_lock_gate.dart
//
// Wraps the whole app. When app lock is on:
//  - the app starts locked,
//  - it locks again after being in the background for 20+ seconds
//    (short interruptions such as permission pop-ups or the share sheet do not re-lock),
//  - a privacy cover hides the content in the app switcher.
// If the phone no longer has any screen lock, the gate unlocks instead of trapping the user.
import 'package:flutter/material.dart';

import '../services/lock_service.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.enabled,
    required this.lockService,
    required this.child,
  });

  final bool enabled;
  final LockService lockService;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  static const Duration _grace = Duration(seconds: 20);

  late bool _locked;
  bool _authenticating = false;
  bool _covered = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locked = widget.enabled;
    if (_locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
    }
  }

  @override
  void didUpdateWidget(covariant AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      // Turning the lock on or off happens inside the app, so never lock the user out mid-session.
      _locked = false;
      _covered = false;
      _leftAt = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled) return;
    switch (state) {
      case AppLifecycleState.resumed:
        final DateTime? left = _leftAt;
        _leftAt = null;
        bool lock = _locked;
        if (left != null && DateTime.now().difference(left) >= _grace) lock = true;
        setState(() {
          _covered = false;
          _locked = lock;
        });
        if (lock) _authenticate();
        break;
      case AppLifecycleState.inactive:
        if (!_authenticating && !_locked) setState(() => _covered = true);
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _leftAt ??= DateTime.now();
        if (!_authenticating && !_locked) setState(() => _covered = true);
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _authenticate() async {
    if (_authenticating || !mounted) return;
    setState(() => _authenticating = true);

    bool ok;
    if (!await widget.lockService.isSupported()) {
      ok = true; // nothing to authenticate with: do not trap the user
    } else {
      ok = await widget.lockService.authenticate('Unlock AirEngine');
    }

    if (!mounted) return;
    setState(() {
      _authenticating = false;
      if (ok) {
        _locked = false;
        _covered = false;
        _leftAt = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool showOverlay = widget.enabled && (_locked || _covered);
    return Stack(
      children: [
        widget.child,
        if (showOverlay)
          Positioned.fill(
            child: _LockScreen(
              showButton: _locked,
              busy: _authenticating,
              onUnlock: _authenticate,
            ),
          ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.showButton, required this.busy, required this.onUnlock});

  final bool showButton;
  final bool busy;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 56, color: Colors.teal.shade700),
            const SizedBox(height: 16),
            const Text('AirEngine is locked', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (showButton) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: busy ? null : onUnlock,
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('Unlock'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
