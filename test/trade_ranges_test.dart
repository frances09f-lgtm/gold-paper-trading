import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/chart/candle_chart.dart';
import 'package:gold_paper_trading/market_data/models.dart';

void main() {
  test('range spec maps durations to real provider intervals', () {
    expect(tradeRangeSpec('range:1H'), ('1min', 120));
    expect(tradeRangeSpec('range:1Y'), ('1day', 400));
    final end = DateTime(2026, 10, 8);
    final data = List.generate(
      400,
      (i) => Candle(
        time: end.subtract(Duration(days: 399 - i)),
        open: 100,
        high: 101,
        low: 99,
        close: 100,
      ),
    );
    expect(trimTradeRange(data, 'range:1W').length, 8);
    expect(trimTradeRange(data, 'range:1Y').length, 366);
  });
  testWidgets(
    'range selector reloads actual range and never calls interval alias',
    (t) async {
      final calls = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 550,
              child: CandleChartPanel(
                rangeMode: true,
                loader: (c) async {
                  calls.add(c);
                  return [];
                },
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(calls, ['range:1D']);
      await t.tap(find.text('1M'));
      await t.pumpAndSettle();
      expect(calls.last, 'range:1M');
      expect(find.text('1m'), findsNothing);
      await t.tap(find.text('Candle intervals'));
      await t.pumpAndSettle();
      expect(calls.last, '1min');
      expect(find.text('1m'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('old failed range request cannot overwrite newer chart', (
    t,
  ) async {
    final old = Completer<List<Candle>>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 650,
            child: CandleChartPanel(
              rangeMode: true,
              loader: (c) async {
                if (c == 'range:1D') return old.future;
                return [];
              },
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.tap(find.text('1M'));
    await t.pumpAndSettle();
    old.completeError(Exception('old range failed'));
    await t.pumpAndSettle();
    expect(find.textContaining('old range failed'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
