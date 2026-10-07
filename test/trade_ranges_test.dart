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
      expect(t.takeException(), isNull);
    },
  );
}
