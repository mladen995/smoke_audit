// lib/utils/time_codec.dart
//
// Timestamps are stored as UTC ISO-8601 strings so they stay correct when the
// phone changes time zone or daylight saving starts/ends. Data written by older
// versions has no "Z"; it is read as local time (the best that can be done).

class TimeCodec {
  TimeCodec._();

  /// Storage format: always UTC, always ends with "Z".
  static String encode(DateTime t) => t.toUtc().toIso8601String();

  /// Parses stored text and returns it in the device's current local time.
  static DateTime decode(String s) => DateTime.parse(s).toLocal();

  static DateTime? tryDecode(String? s) {
    if (s == null) return null;
    final d = DateTime.tryParse(s);
    return d?.toLocal();
  }

  /// "+05:30", "-06:00", "+00:00"
  static String formatOffset(Duration offset) {
    final int totalMinutes = offset.inMinutes;
    final String sign = totalMinutes < 0 ? '-' : '+';
    final int abs = totalMinutes.abs();
    final String hh = (abs ~/ 60).toString().padLeft(2, '0');
    final String mm = (abs % 60).toString().padLeft(2, '0');
    return '$sign$hh:$mm';
  }

  /// Local wall-clock time with its UTC offset, e.g. 2026-11-03T20:28:00-06:00
  static String isoWithOffset(DateTime t) {
    final DateTime l = t.toLocal();
    final String date = '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}';
    final String time = '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
    return '${date}T$time${formatOffset(l.timeZoneOffset)}';
  }

  /// 2026-11-03 (local)
  static String ymd(DateTime t) {
    final DateTime l = t.toLocal();
    return '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}';
  }

  /// 2026-11-03 20:28 (local)
  static String ymdHm(DateTime t) {
    final DateTime l = t.toLocal();
    return '${ymd(l)} ${_two(l.hour)}:${_two(l.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
