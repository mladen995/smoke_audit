// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app_controller.dart';
import 'breath_test_screen.dart';
import 'models/user_profile.dart';
import 'onboarding_screen.dart';
import 'repositories/app_repository.dart';
import 'services/export_service.dart';
import 'services/lock_service.dart';
import 'services/reminder_service.dart';
import 'widgets/app_lock_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting(); // all locales, so dates format correctly everywhere
  final AppRepository repo = AppRepository();
  await repo.init(); // runs data migration if needed
  final AppController controller = AppController(repo);
  await controller.load();
  await ReminderService.instance.init();
  ExportService.cleanupTempFiles(); // remove leftovers from earlier exports (not awaited on purpose)
  runApp(MyApp(repo: repo, controller: controller));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.repo, required this.controller});

  final AppRepository repo;
  final AppController controller;

  static final LockService _lockService = LockService();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'AirEngine',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // supportedLocales is left at its default on purpose: the callback below accepts any
          // language Flutter has Material translations for, and falls back to English otherwise.
          localeResolutionCallback: (Locale? locale, Iterable<Locale> supported) {
            if (locale != null && GlobalMaterialLocalizations.delegate.isSupported(locale)) {
              return locale;
            }
            return const Locale('en', 'US');
          },
          builder: (context, child) => AppLockGate(
            enabled: controller.settings.appLockEnabled,
            lockService: _lockService,
            child: child ?? const SizedBox.shrink(),
          ),
          home: AppRoot(repo: repo, controller: controller),
        );
      },
    );
  }
}

/// Decides between onboarding and the main screen.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.repo, required this.controller});

  final AppRepository repo;
  final AppController controller;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  UserProfile? _profile;
  DateTime? _suggestedQuitDate;
  bool _loading = true;
  int _epoch = 0; // bumped after a restore so the main screen rebuilds from scratch

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final UserProfile? profile = await widget.repo.loadActiveProfile();
    DateTime? suggested;
    if (profile == null) {
      // Existing (v1) users: pre-fill their quit date from their oldest log.
      suggested = await widget.repo.oldestLogTimestamp(AppRepository.legacyProfileId);
    }
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _suggestedQuitDate = suggested;
      _loading = false;
      _epoch++;
    });
  }

  Future<void> _onOnboardingComplete(UserProfile profile) async {
    await widget.repo.saveProfile(profile);
    if (!mounted) return;
    setState(() => _profile = profile);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final UserProfile? profile = _profile;
    if (profile == null) {
      return OnboardingScreen(
        profileId: AppRepository.legacyProfileId, // first profile keeps migrated v1 logs
        suggestedQuitDate: _suggestedQuitDate,
        onComplete: _onOnboardingComplete,
      );
    }

    return BreathTestScreen(
      key: ValueKey('${profile.id}-$_epoch'),
      repo: widget.repo,
      controller: widget.controller,
      profile: profile,
      onProfileChanged: (UserProfile p) => setState(() => _profile = p),
      onDataReplaced: _load, // restore may have changed the active profile
    );
  }
}
