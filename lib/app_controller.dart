// lib/app_controller.dart
import 'package:flutter/foundation.dart';

import 'models/app_settings.dart';
import 'repositories/app_repository.dart';

/// Holds app-wide settings and notifies listeners when they change.
class AppController extends ChangeNotifier {
  AppController(this.repo);

  final AppRepository repo;

  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;

  Future<void> load() async {
    _settings = await repo.loadSettings();
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    _settings = next;
    notifyListeners();
    await repo.saveSettings(next);
  }
}
