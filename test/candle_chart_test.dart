import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/chart/candle_chart.dart';
import 'package:gold_paper_trading/market_data/models.dart';

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
}

/// Deterministic synthetic candles for TESTS ONLY (golden render input).
/// The app never fabricates candles; tests do, to verify the painter.
List<Candle> fakeCandles(int n) {
  final rnd = math.Random(42);
  double px = 4100;
  final base = DateTime(2026, 10, 6, 9, 0);
  return List.generate(n, (i) {
    final o = px;
    final drift = (rnd.nextDouble() - 0.48) * 8;
    final c = o + drift;
    final h = math.max(o, c) + rnd.nextDouble() * 3;
    final l = math.min(o, c) - rnd.nextDouble() * 3;
    px = c;
    return Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: o, high: h, low: l, close: c);
  });
}

void main() {
  testWidgets('CandleChartPanel renders candles from loader', (tester) async {
    await loadFonts();
    final data = fakeCandles(60);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1115),
        body: Center(
          child: SizedBox(
            width: 380,
            height: 340,
            child: CandleChartPanel(
              loader: (iv) async => data,
              livePrice: data.last.close + 1.5,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('XAU/USD'), findsOneWidget);
    expect(find.textContaining('O '), findsOneWidget); // OHLC legend
  });

  testWidgets('chart with indicators renders (golden)', (tester) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1115),
        body: Center(
          child: SizedBox(
            width: 380,
            height: 420,
            child: CandleChartPanel(
              loader: (iv) async => data,
              livePrice: data.last.close + 1.5,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RSI'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(CandleChartPanel), matchesGoldenFile('goldens/chart_indicators.png'));
  });

  testWidgets('CandleChartPanel without loader says feed not configured',
      (tester) async {
    await loadFonts();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CandleChartPanel(loader: null)),
    ));
    await tester.pump();
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(find.textContaining('no demo bars'), findsOneWidget);
  });

  testWidgets('CandleChartPanel surfaces loader errors honestly',
      (tester) async {
    await loadFonts();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CandleChartPanel(
          loader: (iv) async =>
              throw Exception('twelvedata error: rate limit'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('rate limit'), findsOneWidget);
  });

  testWidgets('draw mode places and removes horizontal lines', (tester) async {
    await loadFonts();
    final data = fakeCandles(40);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 340,
          child: CandleChartPanel(loader: (iv) async => data),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CandleChartPanel));
    await tester.tapAt(Offset(center.dx, center.dy - 20));
    await tester.pumpAndSettle();
    final state =
        tester.state<CandleChartPanelState>(find.byType(CandleChartPanel));
    expect(state.hLines.length, 1);
    // tap near the same price removes it
    await tester.tapAt(Offset(center.dx, center.dy - 20));
    await tester.pumpAndSettle();
    expect(state.hLines, isEmpty);
  });

  testWidgets('interval switch reloads', (tester) async {
    await loadFonts();
    final calls = <String>[];
    final data = fakeCandles(30);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CandleChartPanel(
          loader: (iv) async {
            calls.add(iv);
            return data;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1H'));
    await tester.pumpAndSettle();
    expect(calls, containsAll(['15min', '1h']));
  });
}
