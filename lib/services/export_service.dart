// lib/services/export_service.dart
//
// CSV and PDF generation. buildCsv / pdfSafe / filterRange are pure functions
// (unit-tested); buildPdf only needs the `pdf` package (no device APIs).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../logic/tracker_logic.dart';
import '../models/breath_log.dart';
import '../models/user_profile.dart';
import '../utils/time_codec.dart';

class ExportService {
  ExportService._();

  /// Every temporary file we create starts with this, so stale ones can be cleaned up.
  static const String filePrefix = 'AirEngine_';

  // ───────────────────────── temp files ─────────────────────────

  static String stamp(DateTime t) {
    final DateTime l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}${two(l.month)}${two(l.day)}_${two(l.hour)}${two(l.minute)}';
  }

  static Future<String> writeTempBytes(String fileName, List<int> bytes) async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  static Future<String> writeTempString(String fileName, String content) =>
      writeTempBytes(fileName, utf8.encode(content));

  /// Deletes a shared file a little later (the share sheet may still be reading it).
  static void deleteLater(String path, {Duration after = const Duration(minutes: 2)}) {
    Future<void>.delayed(after, () async {
      try {
        final File f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });
  }

  /// Health data should not linger in the cache: remove old exports at startup.
  static Future<void> cleanupTempFiles({Duration olderThan = const Duration(hours: 1)}) async {
    try {
      final Directory dir = await getTemporaryDirectory();
      final DateTime cutoff = DateTime.now().subtract(olderThan);
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File) {
          final String name = e.uri.pathSegments.last;
          if (name.startsWith(filePrefix) && (await e.lastModified()).isBefore(cutoff)) {
            await e.delete();
          }
        }
      }
    } catch (_) {}
  }

  // ───────────────────────── shared helpers ─────────────────────────

  /// Keeps entries between [start] and the END of the [end] day (both optional).
  static Iterable<BreathLog> filterRange(Iterable<BreathLog> logs, DateTime? start, DateTime? end) {
    final DateTime? endInclusive = end == null ? null : DateTime(end.year, end.month, end.day, 23, 59, 59);
    return logs.where((l) =>
        (start == null || !l.timestamp.isBefore(start)) &&
        (endInclusive == null || !l.timestamp.isAfter(endInclusive)));
  }

  static String recordType(BreathLog l) {
    if (l.kind == LogKind.cravingMarker || l.context == TestContext.cravingThreat) return 'craving_event';
    if (l.context == TestContext.relapseSlip) return 'slip_up_event';
    if (l.duration.inMilliseconds > 0) return 'breath_test';
    return 'tracking_start';
  }

  static String contextName(TestContext c) {
    switch (c) {
      case TestContext.standardBaseline:
        return 'standard_test';
      case TestContext.postExposure:
        return 'after_secondhand_smoke';
      case TestContext.relapseSlip:
        return 'slip_up';
      case TestContext.cravingThreat:
        return 'craving';
      case TestContext.afterSmoking:
        return 'after_smoking';
    }
  }

  static String sourceName(BreathLog l) {
    switch (recordType(l)) {
      case 'craving_event':
        return 'shield_button';
      case 'slip_up_event':
        return 'manual';
      case 'tracking_start':
        return 'system';
      default:
        return l.kind == LogKind.baselineSession ? 'baseline_session' : 'microphone';
    }
  }

  // ───────────────────────── CSV ─────────────────────────

  static const List<String> _csvBaseHeader = [
    'record_type',
    'timestamp_local',
    'utc_offset',
    'timestamp_utc',
    'context',
    'exhale_seconds',
    'score_vs_baseline_pct',
    'source',
  ];

  /// One row per entry, oldest first. Location columns are only added when
  /// [includeLocation] is true, and coordinates are rounded to 2 decimals (about 1 km).
  static String buildCsv({
    required List<BreathLog> logs,
    double? baselineSeconds,
    bool includeLocation = false,
    DateTime? start,
    DateTime? end,
  }) {
    final List<String> header = [..._csvBaseHeader, if (includeLocation) ...['latitude', 'longitude']];
    final List<BreathLog> rows = filterRange(logs, start, end).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final StringBuffer sb = StringBuffer()..writeln(header.join(','));
    for (final BreathLog l in rows) {
      final double seconds = l.duration.inMilliseconds / 1000.0;
      final bool measured = l.duration.inMilliseconds > 0;
      final int? score = measured ? TrackerLogic.scoreFor(seconds, baselineSeconds) : null;
      final List<String> cols = [
        recordType(l),
        TimeCodec.isoWithOffset(l.timestamp),
        TimeCodec.formatOffset(l.timestamp.toLocal().timeZoneOffset),
        TimeCodec.encode(l.timestamp),
        contextName(l.context),
        measured ? seconds.toStringAsFixed(2) : '',
        score?.toString() ?? '',
        sourceName(l),
        if (includeLocation) ...[_coord(l.latitude), _coord(l.longitude)],
      ];
      sb.writeln(cols.map(_csvEscape).join(','));
    }
    return sb.toString();
  }

  static String _coord(double? v) => v == null ? '' : v.toStringAsFixed(2);

  static String _csvEscape(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  // ───────────────────────── PDF ─────────────────────────

  /// The built-in PDF font only covers Latin-1, so common accented letters are
  /// mapped to plain ones and anything else becomes "?".
  static String pdfSafe(String s) {
    const Map<String, String> map = {
      'č': 'c', 'ć': 'c', 'š': 's', 'ž': 'z', 'đ': 'd',
      'Č': 'C', 'Ć': 'C', 'Š': 'S', 'Ž': 'Z', 'Đ': 'D',
      'ł': 'l', 'Ł': 'L', 'ś': 's', 'Ś': 'S', 'ź': 'z', 'Ź': 'Z', 'ż': 'z', 'Ż': 'Z',
      'ą': 'a', 'Ą': 'A', 'ę': 'e', 'Ę': 'E', 'ń': 'n', 'Ń': 'N',
      'ő': 'o', 'Ő': 'O', 'ű': 'u', 'Ű': 'U',
      'ř': 'r', 'Ř': 'R', 'ě': 'e', 'Ě': 'E', 'ň': 'n', 'Ň': 'N',
      'ď': 'd', 'Ď': 'D', 'ť': 't', 'Ť': 'T', 'ů': 'u', 'Ů': 'U',
      'ğ': 'g', 'Ğ': 'G', 'ş': 's', 'Ş': 'S', 'ı': 'i', 'İ': 'I',
      'ă': 'a', 'Ă': 'A', 'ș': 's', 'Ș': 'S', 'ț': 't', 'Ț': 'T',
    };
    final StringBuffer b = StringBuffer();
    for (final int r in s.runes) {
      final String ch = String.fromCharCode(r);
      final String? m = map[ch];
      if (m != null) {
        b.write(m);
      } else if (r <= 0xFF) {
        b.write(ch);
      } else {
        b.write('?');
      }
    }
    return b.toString();
  }

  static String _fmtDuration(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} d ${d.inHours % 24} h';
    if (d.inHours >= 1) return '${d.inHours} h ${d.inMinutes % 60} min';
    return '${d.inMinutes} min';
  }

  static String _testTypeLabel(BreathLog l) {
    if (l.kind == LogKind.baselineSession) return 'Baseline session';
    switch (l.context) {
      case TestContext.postExposure:
        return 'After secondhand smoke';
      case TestContext.afterSmoking:
        return 'After smoking';
      default:
        return 'Standard test';
    }
  }

  static String _sexLabel(BiologicalSex s) {
    switch (s) {
      case BiologicalSex.male:
        return 'Male';
      case BiologicalSex.female:
        return 'Female';
      case BiologicalSex.unspecified:
        return 'Not specified';
    }
  }

  /// One-to-two page clinician summary. Dates are ISO (yyyy-MM-dd) so they read
  /// the same in every country and never need non-Latin glyphs.
  static Future<Uint8List> buildPdf({
    required UserProfile profile,
    required List<BreathLog> logs,
    required DateTime now,
    DateTime? rangeStart,
    DateTime? rangeEnd,
    bool useLetter = true,
  }) async {
    final PdfPageFormat format = useLetter ? PdfPageFormat.letter : PdfPageFormat.a4;
    const double margin = 36;
    final double contentWidth = format.width - margin * 2;

    final double? baseline = TrackerLogic.baselineSeconds(logs);
    final double? current = TrackerLogic.currentSeconds(logs, {TestContext.standardBaseline}, now);
    final int? score = TrackerLogic.scoreFor(current, baseline);
    final Duration streak = TrackerLogic.streakElapsed(profile.quitDate, logs, now);
    final Duration longest = TrackerLogic.longestStreak(profile.quitDate, logs, now);

    final List<BreathLog> inRange = filterRange(logs, rangeStart, rangeEnd).toList();
    final List<BreathLog> tests = inRange
        .where((l) => l.duration.inMilliseconds > 0 && recordType(l) == 'breath_test')
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp)); // newest first
    final List<BreathLog> chartTests =
        tests.where((l) => l.context == TestContext.standardBaseline).toList().reversed.toList(); // oldest first
    final List<BreathLog> slips = inRange.where((l) => TrackerLogic.isRelapseContext(l.context)).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final int urges = inRange.where((l) => l.kind == LogKind.cravingMarker).length;
    final Map<String, int> byBucket = TrackerLogic.urgeCountsByBucket(inRange);

    final String periodText = (rangeStart == null && rangeEnd == null)
        ? 'All recorded data'
        : '${rangeStart == null ? 'Start' : TimeCodec.ymd(rangeStart)} to ${rangeEnd == null ? TimeCodec.ymd(now) : TimeCodec.ymd(rangeEnd)}';

    // ── small styling helpers ──
    pw.TextStyle body([double size = 9.5, PdfColor? color]) => pw.TextStyle(fontSize: size, color: color);

    pw.Widget heading(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 14, bottom: 4),
          child: pw.Text(t,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
        );

    pw.Widget kv(String k, String v) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 125, child: pw.Text(k, style: body(9.5, PdfColors.grey700))),
              pw.Expanded(child: pw.Text(v, style: body())),
            ],
          ),
        );

    pw.Widget cell(String t, {bool bold = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(t,
              style: pw.TextStyle(fontSize: 8.5, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        );

    pw.Widget table(List<String> headers, List<List<String>> rows, Map<int, pw.TableColumnWidth> widths) {
      return pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: widths,
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [for (final String h in headers) cell(h, bold: true)],
          ),
          for (final List<String> r in rows) pw.TableRow(children: [for (final String c in r) cell(c)]),
        ],
      );
    }

    pw.Widget trendChart() {
      final List<double> values = chartTests.map((l) => l.duration.inMilliseconds / 1000.0).toList();
      if (values.length < 2) {
        return pw.Text('Not enough standard tests in this period to draw a trend.',
            style: body(9, PdfColors.grey700));
      }
      double lo = values.reduce(min);
      double hi = values.reduce(max);
      if (baseline != null) {
        lo = min(lo, baseline);
        hi = max(hi, baseline);
      }
      if (hi - lo < 1) hi = lo + 1;
      final double pad = (hi - lo) * 0.1;
      lo = max(0.0, lo - pad);
      hi = hi + pad;
      final double span = hi - lo;
      final double? base = baseline;

      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.CustomPaint(
            size: PdfPoint(contentWidth, 130),
            painter: (PdfGraphics canvas, PdfPoint size) {
              final double w = size.x;
              final double h = size.y;
              double yOf(double v) => (v - lo) / span * h;
              double xOf(int i) => i * (w / (values.length - 1));

              canvas
                ..setStrokeColor(PdfColors.grey400)
                ..setLineWidth(0.5)
                ..drawRect(0, 0, w, h)
                ..strokePath();

              if (base != null) {
                final double y = yOf(base);
                canvas
                  ..setStrokeColor(PdfColors.orange700)
                  ..setLineWidth(0.8);
                for (double x = 0; x < w; x += 8) {
                  canvas
                    ..moveTo(x, y)
                    ..lineTo(min(x + 4, w), y);
                }
                canvas.strokePath();
              }

              canvas
                ..setStrokeColor(PdfColors.teal700)
                ..setLineWidth(1.4);
              for (int i = 0; i < values.length; i++) {
                if (i == 0) {
                  canvas.moveTo(xOf(i), yOf(values[i]));
                } else {
                  canvas.lineTo(xOf(i), yOf(values[i]));
                }
              }
              canvas.strokePath();

              if (values.length <= 60) {
                canvas.setFillColor(PdfColors.teal700);
                for (int i = 0; i < values.length; i++) {
                  canvas
                    ..drawEllipse(xOf(i), yOf(values[i]), 2, 2)
                    ..fillPath();
                }
              }
            },
          ),
          pw.SizedBox(height: 3),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(TimeCodec.ymd(chartTests.first.timestamp), style: body(8, PdfColors.grey700)),
              pw.Text(
                'Exhale seconds, ${lo.toStringAsFixed(1)} to ${hi.toStringAsFixed(1)}'
                '${baseline != null ? '  (dashed line = personal baseline)' : ''}',
                style: body(8, PdfColors.grey700),
              ),
              pw.Text(TimeCodec.ymd(chartTests.last.timestamp), style: body(8, PdfColors.grey700)),
            ],
          ),
        ],
      );
    }

    // ── profile text ──
    final String name = profile.displayName.trim().isEmpty ? 'Not provided' : pdfSafe(profile.displayName.trim());
    final int totalIn = (profile.heightCm / 2.54).round();
    final String height = '${profile.heightCm.round()} cm (${totalIn ~/ 12} ft ${totalIn % 12} in)';
    String history = 'Not provided';
    if (profile.cigarettesPerDay != null || profile.yearsSmoked != null) {
      final List<String> parts = [];
      if (profile.cigarettesPerDay != null) parts.add('${profile.cigarettesPerDay} cigarettes/day');
      if (profile.yearsSmoked != null) parts.add('${profile.yearsSmoked} years');
      history = parts.join(' for ');
      final double? py = profile.packYears;
      if (py != null) history += ' (${py.toStringAsFixed(1)} pack-years)';
    }
    final bool planning = profile.quitDate.isAfter(now);

    final pw.Document doc = pw.Document(title: 'AirEngine summary', author: 'AirEngine');
    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(margin),
        footer: (pw.Context c) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: body(8, PdfColors.grey600)),
        ),
        build: (pw.Context c) => [
          pw.Text('AirEngine - Breath & Smoke-Free Progress Summary',
              style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 3),
          pw.Text('Generated ${TimeCodec.isoWithOffset(now)}   |   Period: $periodText',
              style: body(9, PdfColors.grey700)),
          pw.SizedBox(height: 6),
          pw.Container(
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(color: PdfColors.amber50, border: pw.Border.all(color: PdfColors.amber300, width: 0.5)),
            child: pw.Text(
              'Self-tracked wellness data from a phone app. It is not a medical device, not spirometry, '
              'and not a diagnostic test. Please read it as context for a conversation with a clinician.',
              style: body(8.5),
            ),
          ),

          heading('Patient profile (self-reported)'),
          kv('Name', name),
          kv('Age', '${profile.ageYears} years'),
          kv('Sex (as entered)', _sexLabel(profile.sex)),
          kv('Height', height),
          kv('Smoking history', history),
          kv(planning ? 'Planned quit date' : 'Quit date', TimeCodec.ymdHm(profile.quitDate)),

          heading('Smoke-free progress'),
          kv('Current streak', planning ? 'Starts on the planned quit date' : _fmtDuration(streak)),
          kv('Longest streak', _fmtDuration(longest)),
          kv('Slip-ups logged (period)', '${slips.length}'),
          kv('Urges ridden out (period)', '$urges'),

          heading('Breath measurements'),
          kv('Personal baseline',
              baseline == null ? 'Not set' : '${baseline.toStringAsFixed(1)} s (median of 3 guided tests)'),
          kv('Recent level (30 days)',
              current == null ? 'No recent tests' : '${current.toStringAsFixed(1)} s (median of latest tests)'),
          kv('Score vs baseline',
              score == null ? '-' : '$score  (100 = personal baseline; ${score >= 100 ? '+' : ''}${score - 100}%)'),
          kv('Tests in period', '${tests.length}'),
          pw.SizedBox(height: 8),
          trendChart(),
          pw.SizedBox(height: 8),
          if (tests.isEmpty)
            pw.Text('No breath tests in this period.', style: body(9, PdfColors.grey700))
          else
            table(
              ['Date / time (local)', 'Type', 'Exhale (s)', 'vs baseline'],
              [
                for (final BreathLog l in tests.take(30))
                  [
                    TimeCodec.ymdHm(l.timestamp),
                    _testTypeLabel(l),
                    (l.duration.inMilliseconds / 1000.0).toStringAsFixed(1),
                    () {
                      final int? s = TrackerLogic.scoreFor(l.duration.inMilliseconds / 1000.0, baseline);
                      return s == null ? '-' : '$s%';
                    }(),
                  ],
              ],
              {
                0: const pw.FlexColumnWidth(2.2),
                1: const pw.FlexColumnWidth(2.2),
                2: const pw.FlexColumnWidth(1),
                3: const pw.FlexColumnWidth(1),
              },
            ),
          if (tests.length > 30)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 3),
              child: pw.Text('Showing the 30 most recent of ${tests.length} tests.', style: body(8, PdfColors.grey700)),
            ),

          heading('Cravings and slip-ups'),
          pw.Text('When urges were logged (time of day):', style: body(9, PdfColors.grey700)),
          pw.SizedBox(height: 3),
          table(
            ['Time of day', 'Urges / slip-ups logged'],
            [
              for (final MapEntry<String, int> e in byBucket.entries) [e.key, '${e.value}'],
            ],
            {0: const pw.FlexColumnWidth(2), 1: const pw.FlexColumnWidth(2)},
          ),
          pw.SizedBox(height: 6),
          if (slips.isEmpty)
            pw.Text('No slip-ups logged in this period.', style: body(9, PdfColors.grey700))
          else
            pw.Text(
              'Slip-ups: ${slips.take(12).map((l) => TimeCodec.ymdHm(l.timestamp)).join(', ')}'
              '${slips.length > 12 ? ' (+${slips.length - 12} more)' : ''}',
              style: body(9),
            ),

          heading('How these numbers were measured'),
          pw.Text(
            'Exhale duration is measured with the phone microphone: from the first sustained blowing sound '
            'until it stops. Results depend on the phone, its position and room noise, so they are only '
            'meaningful as a trend for the same person using the same phone. They cannot be compared to '
            'clinical values (FEV1, FVC, peak flow) or to other people. The score compares recent tests to '
            'the person\'s own baseline (the median of three guided tests). The quit date, slip-ups and '
            'cravings are entered by the user and have not been verified.',
            style: body(8.5),
          ),
        ],
      ),
    );

    return doc.save();
  }
}
