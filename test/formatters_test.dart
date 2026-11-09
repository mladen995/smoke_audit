import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:smoke_audit/utils/formatters.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting();
  });

  test('dates follow the locale', () {
    final d = DateTime(2026, 3, 5);
    expect(Fmt.dateFor('en_US', d), '3/5/2026');
    expect(Fmt.dateFor('de_DE', d), '5.3.2026');
  });

  test('24 hour time', () {
    expect(Fmt.timeFor('en_US', DateTime(2026, 3, 5, 14, 5), use24h: true), '14:05');
  });

  test('an unknown locale falls back instead of crashing', () {
    expect(Fmt.dateFor('xx_YY', DateTime(2026, 3, 5)), isNotEmpty);
  });

  test('imperial only by default for US, Liberia and Myanmar', () {
    expect(Fmt.defaultsToImperial(const Locale('en', 'US')), isTrue);
    expect(Fmt.defaultsToImperial(const Locale('en', 'GB')), isFalse);
    expect(Fmt.defaultsToImperial(const Locale('de', 'DE')), isFalse);
    expect(Fmt.defaultsToImperial(const Locale('en')), isFalse);
  });

  test('decimals and money', () {
    expect(Fmt.decimalFor('en_US', 12.5), '12.5');
    expect(Fmt.decimalFor('de_DE', 12.5), '12,5');
    expect(Fmt.moneyFor('en_US', 15), '\$15.00');
    expect(Fmt.currencySymbolFor('en_US'), '\$');
  });
}
