import 'package:flutter_test/flutter_test.dart';
import 'package:smoke_audit/models/breath_log.dart';
import 'package:smoke_audit/services/export_service.dart';

import 'test_helpers.dart';

void main() {
  final test1 = makeLog(id: 't', at: DateTime.utc(2026, 10, 3, 12), seconds: 12.5);
  final craving = makeLog(
    id: 'c',
    at: DateTime.utc(2026, 10, 2, 12),
    kind: LogKind.cravingMarker,
    context: TestContext.cravingThreat,
    lat: 41.87819,
    lng: -87.6298,
  );
  final slip = makeLog(
      id: 's', at: DateTime.utc(2026, 10, 4, 12), kind: LogKind.userSlip, context: TestContext.relapseSlip, isManual: true);

  group('labels', () {
    test('record types', () {
      expect(ExportService.recordType(craving), 'craving_event');
      expect(ExportService.recordType(slip), 'slip_up_event');
      expect(ExportService.recordType(test1), 'breath_test');
      expect(ExportService.recordType(makeLog(id: 'z', at: DateTime.utc(2026, 1, 1))), 'tracking_start');
    });

    test('sources', () {
      expect(ExportService.sourceName(craving), 'shield_button');
      expect(ExportService.sourceName(slip), 'manual');
      expect(ExportService.sourceName(test1), 'microphone');
      expect(
        ExportService.sourceName(makeLog(id: 'b', at: DateTime.utc(2026, 1, 1), kind: LogKind.baselineSession, seconds: 9)),
        'baseline_session',
      );
    });

    test('context names are readable for every value', () {
      for (final c in TestContext.values) {
        expect(ExportService.contextName(c), isNotEmpty);
      }
    });

    test('file stamp has no characters that break file names', () {
      final String s = ExportService.stamp(DateTime(2026, 3, 5, 7, 9));
      expect(s, '20260305_0709');
    });
  });

  group('CSV', () {
    const base = 'record_type,timestamp_local,utc_offset,timestamp_utc,context,exhale_seconds,score_vs_baseline_pct,source';

    test('header without location', () {
      final lines = ExportService.buildCsv(logs: [test1]).trim().split('\n');
      expect(lines.first, base);
      expect(lines.length, 2);
    });

    test('rows are oldest first and carry score against the baseline', () {
      final lines = ExportService.buildCsv(logs: [slip, test1, craving], baselineSeconds: 10).trim().split('\n');
      expect(lines.length, 4);
      final cols = lines[2].split(','); // second oldest = the test
      expect(cols[0], 'breath_test');
      expect(cols[5], '12.50');
      expect(cols[6], '125');
      expect(cols[7], 'microphone');
      expect(lines[1].split(',')[0], 'craving_event');
      expect(lines[3].split(',')[0], 'slip_up_event');
    });

    test('entries without a measurement have empty seconds and score', () {
      final cols = ExportService.buildCsv(logs: [craving], baselineSeconds: 10).trim().split('\n')[1].split(',');
      expect(cols[5], '');
      expect(cols[6], '');
    });

    test('location is left out unless asked for', () {
      final csv = ExportService.buildCsv(logs: [craving]);
      expect(csv.contains('latitude'), isFalse);
      expect(csv.contains('41.8'), isFalse);
    });

    test('location is rounded to 2 decimals when included', () {
      final lines = ExportService.buildCsv(logs: [craving], includeLocation: true).trim().split('\n');
      expect(lines.first.endsWith(',latitude,longitude'), isTrue);
      final cols = lines[1].split(',');
      expect(cols[8], '41.88');
      expect(cols[9], '-87.63');
    });

    test('date range keeps whole days', () {
      final logs = [
        makeLog(id: '1', at: DateTime(2026, 10, 1, 12), seconds: 5),
        makeLog(id: '2', at: DateTime(2026, 10, 2, 23, 30), seconds: 5),
        makeLog(id: '3', at: DateTime(2026, 10, 3, 12), seconds: 5),
      ];
      final kept = ExportService.filterRange(logs, DateTime(2026, 10, 2), DateTime(2026, 10, 2)).toList();
      expect(kept.map((l) => l.id).toList(), ['2']);
    });
  });

  group('PDF', () {
    test('pdfSafe maps accents and replaces unsupported characters', () {
      expect(ExportService.pdfSafe('Šime Čorić'), 'Sime Coric');
      expect(ExportService.pdfSafe('Zoë'), 'Zoë');
      expect(ExportService.pdfSafe('日本'), '??');
      expect(ExportService.pdfSafe('plain'), 'plain');
    });

    test('builds a real PDF with data', () async {
      final bytes = await ExportService.buildPdf(
        profile: makeProfile(name: 'Šime'),
        logs: [
          makeLog(id: 'b1', at: DateTime.utc(2026, 10, 2), kind: LogKind.baselineSession, seconds: 10),
          makeLog(id: 'b2', at: DateTime.utc(2026, 10, 2, 0, 1), kind: LogKind.baselineSession, seconds: 11),
          makeLog(id: 'b3', at: DateTime.utc(2026, 10, 2, 0, 2), kind: LogKind.baselineSession, seconds: 12),
          test1,
          craving,
          slip,
        ],
        now: DateTime.utc(2026, 11, 1),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });

    test('builds a PDF with no data at all', () async {
      final bytes = await ExportService.buildPdf(
        profile: makeProfile(cigarettesPerDay: null, yearsSmoked: null, pricePerPack: null),
        logs: const [],
        now: DateTime.utc(2026, 11, 1),
        useLetter: false,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
