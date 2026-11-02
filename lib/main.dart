import 'package:flutter/material.dart';

import 'breath_test_screen.dart';
import 'models/user_profile.dart';
import 'onboarding_screen.dart';
import 'repositories/app_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = AppRepository();
  await repo.init(); // runs data migration if needed
  runApp(MyApp(repo: repo));
}

class MyApp extends StatelessWidget {
  final AppRepository repo;
  const MyApp({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lung Capacity Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: AppRoot(repo: repo),
    );
  }
}

/// Decides between onboarding and the main screen.
class AppRoot extends StatefulWidget {
  final AppRepository repo;
  const AppRoot({super.key, required this.repo});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  UserProfile? _profile;
  DateTime? _suggestedQuitDate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await widget.repo.loadActiveProfile();
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

    final profile = _profile;
    if (profile == null) {
      return OnboardingScreen(
        profileId: AppRepository.legacyProfileId, // first profile keeps migrated v1 logs
        suggestedQuitDate: _suggestedQuitDate,
        onComplete: _onOnboardingComplete,
      );
    }

    return BreathTestScreen(
      key: ValueKey(profile.id),
      repo: widget.repo,
      profile: profile,
    );
  }
}