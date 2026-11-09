// lib/settings_screen.dart
//
// Privacy, reminders, app lock, backup/restore and support, in one place.
// The main screen passes callbacks so it can reload its data and re-sync
// reminders after anything here changes.
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models/app_settings.dart';
import 'repositories/app_repository.dart';
import 'services/backup_service.dart';
import 'services/export_service.dart';
import 'services/lock_service.dart';
import 'services/reminder_service.dart';
import 'support_resources_screen.dart';
import 'utils/formatters.dart';
import 'utils/share_helper.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.repo,
    required this.onDataChanged,
    this.onEditProfile,
    this.onResetProfile,
  });

  final AppController controller;
  final AppRepository repo;

  /// Called after settings, restore or location deletion so the main screen can reload and re-sync reminders.
  final Future<void> Function() onDataChanged;
  final VoidCallback? onEditProfile;
  final VoidCallback? onResetProfile;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final LockService _lock = LockService();
  late final BackupService _backup = BackupService(widget.repo);
  bool _busy = false;

  AppSettings get _s => widget.controller.settings;

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _apply(AppSettings next) async {
    await widget.controller.update(next);
    await widget.onDataChanged();
  }

  // ── reminders ──
  Future<void> _toggleDaily(bool on) async {
    if (on && !await ReminderService.instance.requestPermission()) {
      _msg('Notifications are blocked. Allow them in your phone settings first.');
      return;
    }
    await _apply(_s.copyWith(dailyReminderEnabled: on));
  }

  Future<void> _toggleMilestones(bool on) async {
    if (on && !await ReminderService.instance.requestPermission()) {
      _msg('Notifications are blocked. Allow them in your phone settings first.');
      return;
    }
    await _apply(_s.copyWith(milestoneAlertsEnabled: on));
  }

  Future<void> _pickTime() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _s.reminderHour, minute: _s.reminderMinute),
    );
    if (t == null) return;
    await _apply(_s.copyWith(reminderHour: t.hour, reminderMinute: t.minute));
  }

  // ── app lock ──
  Future<void> _toggleLock(bool on) async {
    if (on) {
      if (!await _lock.isSupported()) {
        _msg('Set a screen lock (PIN, pattern, fingerprint or face) on your phone first.');
        return;
      }
      // Prove it works before turning it on, so the user cannot lock themselves out.
      if (!await _lock.authenticate('Confirm to turn on app lock')) return;
    }
    await _apply(_s.copyWith(appLockEnabled: on));
  }

  // ── location ──
  Future<void> _deleteLocations() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete saved locations?'),
        content: const Text('Coordinates are removed from every saved craving. Everything else is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    final int n = await widget.repo.deleteAllLocations();
    await widget.onDataChanged();
    _msg(n == 0 ? 'No saved locations found.' : 'Removed locations from $n entries.');
  }

  // ── backup ──
  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String path = await _backup.createBackupFile(DateTime.now());
      if (!mounted) return;
      await shareFile(context, path, mimeType: 'application/json');
      ExportService.deleteLater(path);
    } catch (_) {
      _msg('Could not create the backup.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ParsedBackup? parsed = await _backup.pickAndParse();
      if (parsed == null || !mounted) return;

      final String when = parsed.exportedAt == null ? 'unknown date' : Fmt.dateTime(context, parsed.exportedAt!.toLocal());
      final RestoreMode? mode = await showDialog<RestoreMode>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Restore backup'),
          content: Text(
            'Backup from $when: ${parsed.profiles.length} profile(s), ${parsed.totalLogs} entries.'
            '${parsed.skippedEntries > 0 ? '\n${parsed.skippedEntries} unreadable entries will be skipped.' : ''}'
            '\n\nMerge adds what is missing and keeps what you have. Replace erases the data on this phone first.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, RestoreMode.replace), child: const Text('Replace')),
            ElevatedButton(onPressed: () => Navigator.pop(c, RestoreMode.merge), child: const Text('Merge')),
          ],
        ),
      );
      if (mode == null) return;

      final RestorePlan plan = await _backup.restore(parsed, mode);
      await widget.onDataChanged();
      _msg(mode == RestoreMode.merge
          ? 'Restored: ${plan.addedLogs} new entries, ${plan.addedProfiles} new profile(s).'
          : 'Backup restored.');
    } on BackupFormatException catch (e) {
      _msg(e.message);
    } catch (_) {
      _msg('Could not restore that file.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final AppSettings s = _s;
          final String time = Fmt.time(context, DateTime(2000, 1, 1, s.reminderHour, s.reminderMinute));
          return ListView(
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (widget.onEditProfile != null)
                ListTile(
                  leading: const Icon(Icons.person_rounded),
                  title: const Text('Edit profile'),
                  onTap: widget.onEditProfile,
                ),
              const _Header('Privacy'),
              SwitchListTile(
                title: const Text('Save craving location'),
                subtitle: const Text('Off by default. Stored only on this phone.'),
                value: s.saveCravingLocation,
                onChanged: (v) => _apply(s.copyWith(saveCravingLocation: v)),
              ),
              ListTile(
                leading: const Icon(Icons.location_off_rounded),
                title: const Text('Delete all saved locations'),
                onTap: _deleteLocations,
              ),
              SwitchListTile(
                title: const Text('App lock'),
                subtitle: const Text('Ask for fingerprint, face or phone PIN when opening.'),
                value: s.appLockEnabled,
                onChanged: _toggleLock,
              ),
              const _Header('Reminders'),
              SwitchListTile(
                title: const Text('Daily check-in'),
                value: s.dailyReminderEnabled,
                onChanged: _toggleDaily,
              ),
              ListTile(
                enabled: s.dailyReminderEnabled,
                title: const Text('Time'),
                trailing: Text(time),
                onTap: s.dailyReminderEnabled ? _pickTime : null,
              ),
              SwitchListTile(
                title: const Text('Milestone alerts'),
                subtitle: const Text('Notify me when a health milestone is reached.'),
                value: s.milestoneAlertsEnabled,
                onChanged: _toggleMilestones,
              ),
              const _Header('Your data'),
              ListTile(
                leading: const Icon(Icons.backup_rounded),
                title: const Text('Create backup'),
                subtitle: const Text('JSON file you can save or send to yourself.'),
                onTap: _createBackup,
              ),
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('Restore from backup'),
                onTap: _restore,
              ),
              if (widget.onResetProfile != null)
                ListTile(
                  leading: const Icon(Icons.delete_forever_rounded, color: Colors.red),
                  title: const Text('Reset this profile’s data'),
                  onTap: widget.onResetProfile,
                ),
              const _Header('Help'),
              ListTile(
                leading: const Icon(Icons.support_agent_rounded),
                title: const Text('Support & quitlines'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const SupportResourcesScreen()),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal.shade700)),
      );
}
