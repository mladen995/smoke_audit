import 'package:flutter_test/flutter_test.dart';
import 'package:smoke_audit/utils/time_codec.dart';

void main() {
  test('encode writes UTC with a Z suffix', () {
    final String s = TimeCodec.encode(DateTime.utc(2026, 11, 3, 14, 5, 6));
    expect(s.startsWith('2026-11-03T14:05:06'), isTrue);
    expect(s.endsWith('Z'), isTrue);
  });

  test('a local time is also stored as UTC', () {
    expect(TimeCodec.encode(DateTime(2026, 1, 1, 9)).endsWith('Z'), isTrue);
  });

  test('encode then decode keeps the exact moment', () {
    final DateTime t = DateTime.utc(2026, 11, 3, 14, 5, 6);
    expect(TimeCodec.decode(TimeCodec.encode(t)).isAtSameMomentAs(t), isTrue);
  });

  test('a legacy string without Z is read as local time', () {
    final DateTime d = TimeCodec.decode('2026-11-03T14:05:06');
    expect(d.isUtc, isFalse);
    expect(d.hour, 14);
  });

  test('tryDecode handles null and garbage', () {
    expect(TimeCodec.tryDecode(null), isNull);
    expect(TimeCodec.tryDecode('not a date'), isNull);
    expect(TimeCodec.tryDecode('2026-11-03T14:05:06Z'), isNotNull);
  });

  test('formatOffset', () {
    expect(TimeCodec.formatOffset(const Duration(hours: 5, minutes: 30)), '+05:30');
    expect(TimeCodec.formatOffset(const Duration(hours: -6)), '-06:00');
    expect(TimeCodec.formatOffset(Duration.zero), '+00:00');
    expect(TimeCodec.formatOffset(const Duration(hours: -3, minutes: -30)), '-03:30');
  });

  test('isoWithOffset has the expected shape', () {
    expect(
      TimeCodec.isoWithOffset(DateTime(2026, 3, 5, 7, 9, 2)),
      matches(RegExp(r'^2026-03-05T07:09:02[+-]\d\d:\d\d$')),
    );
  });

  test('ymd and ymdHm are zero padded', () {
    expect(TimeCodec.ymd(DateTime(2026, 3, 5)), '2026-03-05');
    expect(TimeCodec.ymdHm(DateTime(2026, 3, 5, 7, 9)), '2026-03-05 07:09');
  });
}
