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
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
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
      open: o,
      high: h,
      low: l,
      close: c,
    );
  });
}

void main() {
  testWidgets('CandleChartPanel renders candles from loader', (tester) async {
    await loadFonts();
    final data = fakeCandles(60);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
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
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('XAU/USD'), findsOneWidget);
    expect(find.textContaining('O '), findsOneWidget); // OHLC legend
  });

  testWidgets('trend bias strip shows readout and expands to reasons', (
    tester,
  ) async {
    await loadFonts();
    final data = fakeCandles(60);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          backgroundColor: const Color(0xFF0F1115),
          body: Center(
            child: SizedBox(
              width: 380,
              height: 480,
              child: CandleChartPanel(loader: (iv) async => data),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Trend bias: '), findsOneWidget);
    await tester.tap(find.textContaining('Trend bias: '), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Not a prediction'), findsOneWidget);
  });

  testWidgets('chart with indicators renders (golden)', (tester) async {
    await loadFonts();
    final data = fakeCandles(80);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
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
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indicators'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RSI 14'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CandleChartPanel),
      matchesGoldenFile('goldens/chart_indicators.png'),
    );
  });

  testWidgets(
    'indicator dropdown offers nine toggles without changing timeframe',
    (t) async {
      await loadFonts();
      await t.binding.setSurfaceSize(const Size(412,850));
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner:false,
          theme:ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 412,
              height: 550,
              child: CandleChartPanel(loader: (_) async => fakeCandles(240)),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final state = t.state<CandleChartPanelState>(
        find.byType(CandleChartPanel),
      );
      await t.tap(find.text('1m'));
      await t.pumpAndSettle();
      await t.tap(find.text('Indicators'));
      await t.pumpAndSettle();
      for (final label in [
        'EMA 9',
        'EMA 21',
        'EMA 50',
        'EMA 200',
        'SMA 20',
        'SMA 200',
        'RSI 14',
        'MACD 12/26/9',
        'Bollinger 20 / 2',
      ])
        expect(find.text(label), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/indicator_dropdown.png'),
      );
      await t.tap(find.text('Bollinger 20 / 2'));
      await t.pumpAndSettle();
      expect(state.bollingerOn, true);
      expect(state.interval.code, '1min');
      await t.tap(find.text('Indicators'));
      await t.pumpAndSettle();
      await t.tap(find.text('EMA 9'));
      await t.pumpAndSettle();
      expect(state.extraEmas, contains(9));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('CandleChartPanel without loader says feed not configured', (
    tester,
  ) async {
    await loadFonts();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CandleChartPanel(loader: null))),
    );
    await tester.pump();
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(find.textContaining('no demo bars'), findsOneWidget);
  });

  testWidgets('CandleChartPanel surfaces loader errors honestly', (
    tester,
  ) async {
    await loadFonts();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          body: CandleChartPanel(
            loader: (iv) async =>
                throw Exception('twelvedata error: rate limit'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('rate limit'), findsOneWidget);
  });

  testWidgets('draw mode places and removes horizontal lines', (tester) async {
    await loadFonts();
    final data = fakeCandles(40);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 340,
            child: CandleChartPanel(loader: (iv) async => data),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CandleChartPanel));
    await tester.tapAt(Offset(center.dx, center.dy - 20));
    await tester.pumpAndSettle();
    final state = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );
    expect(state.hLines.length, 1);
    // tap near the same price removes it
    await tester.tapAt(Offset(center.dx, center.dy - 20));
    await tester.pumpAndSettle();
    expect(state.hLines, isEmpty);
  });

  testWidgets('SMA200 and MACD chips toggle without errors', (tester) async {
    await loadFonts();
    final data = fakeCandles(120);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 480,
            child: CandleChartPanel(loader: (iv) async => data),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indicators'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMA 200'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indicators'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MACD 12/26/9'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('trend mode draws a line with two taps', (tester) async {
    await loadFonts();
    final data = fakeCandles(60);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 340,
            child: CandleChartPanel(loader: (iv) async => data),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trend'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CandleChartPanel));
    await tester.tapAt(Offset(center.dx - 80, center.dy - 20));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(center.dx + 60, center.dy + 10));
    await tester.pumpAndSettle();
    final state = tester.state<CandleChartPanelState>(
      find.byType(CandleChartPanel),
    );
    expect(state.trendLines.length, 1);
    expect(state.pendingTrend, isNull);
  });

  testWidgets('interval switch reloads', (tester) async {
    await loadFonts();
    final calls = <String>[];
    final data = fakeCandles(30);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner:false,
        home: Scaffold(
          body: CandleChartPanel(
            loader: (iv) async {
              calls.add(iv);
              return data;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1H'));
    await tester.pumpAndSettle();
    expect(calls, containsAll(['15min', '1h']));
  });
}
