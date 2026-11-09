// lib/widgets/export_sheet.dart
//
// Bottom sheet for sharing data with a clinician: PDF summary or CSV.
// Location is never included unless the user ticks the box (and only if some entries have it).
import 'package:flutter/material.dart';

import '../logic/tracker_logic.dart';
import '../models/breath_log.dart';
import '../models/user_profile.dart';
import '../services/export_service.dart';
import '../utils/share_helper.dart';

Future<void> showExportSheet(
  BuildContext context, {
  required UserProfile profile,
  required List<BreathLog> logs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ExportSheet(profile: profile, logs: logs),
  );
}

enum _Range { days30, days90, all }

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.profile, required this.logs});
  final UserProfile profile;
  final List<BreathLog> logs;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  _Range _range = _Range.days90;
  bool _includeLocation = false;
  bool _busy = false;

  bool get _hasLocation => widget.logs.any((l) => l.hasLocation);

  DateTime? _start(DateTime now) {
    switch (_range) {
      case _Range.days30:
        return now.subtract(const Duration(days: 30));
      case _Range.days90:
        return now.subtract(const Duration(days: 90));
      case _Range.all:
        return null;
    }
  }

  Future<void> _run(String kind) async {
    if (_busy) return;
    setState(() => _busy = true);
    final DateTime now = DateTime.now();
    final DateTime? start = _start(now);
    String? path;
    try {
      if (kind == 'pdf') {
        final bytes = await ExportService.buildPdf(
          profile: widget.profile,
          logs: widget.logs,
          now: now,
          rangeStart: start,
          rangeEnd: now,
          useLetter: Localizations.localeOf(context).countryCode == 'US',
        );
        path = await ExportService.writeTempBytes(
            '${ExportService.filePrefix}Summary_${ExportService.stamp(now)}.pdf', bytes);
      } else {
        final String csv = ExportService.buildCsv(
          logs: widget.logs,
          baselineSeconds: TrackerLogic.baselineSeconds(widget.logs),
          includeLocation: _includeLocation && _hasLocation,
          start: start,
          end: now,
        );
        path = await ExportService.writeTempString(
            '${ExportService.filePrefix}Data_${ExportService.stamp(now)}.csv', csv);
      }
      if (!mounted) return;
      await shareFile(context, path, mimeType: kind == 'pdf' ? 'application/pdf' : 'text/csv');
      ExportService.deleteLater(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create the export. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Share with your clinician',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('The PDF is a readable summary. The CSV has every row for spreadsheets.',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 14),
            SegmentedButton<_Range>(
              segments: const [
                ButtonSegment(value: _Range.days30, label: Text('30 days')),
                ButtonSegment(value: _Range.days90, label: Text('90 days')),
                ButtonSegment(value: _Range.all, label: Text('All')),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
            if (_hasLocation)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeLocation,
                onChanged: (v) => setState(() => _includeLocation = v ?? false),
                title: const Text('Include craving locations (CSV only)'),
                subtitle: const Text('Rounded to about 1 km.'),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : () => _run('pdf'),
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('PDF summary'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run('csv'),
                    icon: const Icon(Icons.table_chart_rounded),
                    label: const Text('CSV data'),
                  ),
                ),
              ],
            ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
