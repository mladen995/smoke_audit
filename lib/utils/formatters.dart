// lib/utils/formatters.dart
//
// Locale-aware dates, times, currency and default units.
// Pure "...For(locale)" functions are used by services/tests; the BuildContext
// versions pick up the device locale and 12/24-hour preference automatically.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class Fmt {
  Fmt._();

  // ───────────── locale helpers ─────────────

  static String localeName(BuildContext context) => Localizations.localeOf(context).toString();

  /// Falls back to the language alone, then to en_US, when intl has no data.
  static String safeLocale(String locale) {
    if (DateFormat.localeExists(locale)) return locale;
    final String lang = locale.split('_').first;
    if (DateFormat.localeExists(lang)) return lang;
    return 'en_US';
  }

  /// US, Liberia and Myanmar use imperial units; everyone else defaults to metric.
  static bool defaultsToImperial(Locale locale) {
    const imperial = <String>{'US', 'LR', 'MM'};
    return imperial.contains(locale.countryCode);
  }

  // ───────────── pure functions ─────────────

  static String dateFor(String locale, DateTime d) => DateFormat.yMd(safeLocale(locale)).format(d);

  static String timeFor(String locale, DateTime d, {bool use24h = false}) {
    final String loc = safeLocale(locale);
    final DateFormat f = use24h ? DateFormat.Hm(loc) : DateFormat.jm(loc);
    return f.format(d);
  }

  static String dateTimeFor(String locale, DateTime d, {bool use24h = false}) =>
      '${dateFor(locale, d)} ${timeFor(locale, d, use24h: use24h)}';

  static String monthDayFor(String locale, DateTime d) => DateFormat.Md(safeLocale(locale)).format(d);

  static String monthYearFor(String locale, DateTime d) => DateFormat.yM(safeLocale(locale)).format(d);

  static NumberFormat _currency(String locale) {
    try {
      return NumberFormat.simpleCurrency(locale: locale);
    } catch (_) {
      return NumberFormat.simpleCurrency(locale: 'en_US');
    }
  }

  static String moneyFor(String locale, double value) => _currency(locale).format(value);

  static String currencySymbolFor(String locale) => _currency(locale).currencySymbol;

  static String decimalFor(String locale, double value, {int digits = 1}) {
    try {
      return NumberFormat.decimalPatternDigits(locale: safeLocale(locale), decimalDigits: digits).format(value);
    } catch (_) {
      return value.toStringAsFixed(digits);
    }
  }

  // ───────────── BuildContext versions ─────────────

  static bool use24h(BuildContext c) => MediaQuery.alwaysUse24HourFormatOf(c);

  static String date(BuildContext c, DateTime d) => dateFor(localeName(c), d);

  static String time(BuildContext c, DateTime d) => timeFor(localeName(c), d, use24h: use24h(c));

  static String dateTime(BuildContext c, DateTime d) => dateTimeFor(localeName(c), d, use24h: use24h(c));

  static String monthDay(BuildContext c, DateTime d) => monthDayFor(localeName(c), d);

  static String monthYear(BuildContext c, DateTime d) => monthYearFor(localeName(c), d);

  static String money(BuildContext c, double v) => moneyFor(localeName(c), v);

  static String currencySymbol(BuildContext c) => currencySymbolFor(localeName(c));

  static String seconds(BuildContext c, double v, {int digits = 1}) =>
      decimalFor(localeName(c), v, digits: digits);
}
