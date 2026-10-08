import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/main.dart';
import 'package:gold_paper_trading/market_data/models.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:gold_paper_trading/sessions.dart';

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await Future.wait([roboto.load(), icons.load()]);
}

AppState demoState() {
  final app = AppState();
  app.unlocked = true;
  app.price = 4153.70;
  app.bid = 4153.35;
  app.ask = 4154.05;
  app.priceAt = DateTime.now().millisecondsSinceEpoch;
  app.priceOk = true;
  app.starting = 10;
  app.balance = 10;
  app.positions = [
    {
      'id': 'ed587ff8-0e70-4438-ad78-0989daa653b6',
      'direction': 'buy', 'entry': 4152.60, 'qty': 1.0,
      'tp': 4154.0, 'sl': null, 'pnl': null, 'exit': null,
      'status': 'open', 'opened_at': '2026-10-06T14:18:07+00:00',
      'closed_at': null, 'reason': null,
    },
    {
      'id': '0b7ef1d0-12da-4a9f-9ff5-b17f0ca7637c',
      'direction': 'buy', 'entry': 4152.60, 'qty': 1.0,
      'tp': null, 'sl': null, 'pnl': null, 'exit': null,
      'status': 'open', 'opened_at': '2026-10-06T14:17:29+00:00',
      'closed_at': null, 'reason': null,
    },
    {
      'id': '3025cd65-e3d1-4fa4-9e2a-5c191f8e0a18',
      'direction': 'buy', 'entry': 4151.20, 'qty': 2.0,
      'tp': null, 'sl': null, 'pnl': null, 'exit': null,
      'status': 'open', 'opened_at': '2026-10-06T13:02:11+00:00',
      'closed_at': null, 'reason': null,
    },
    {
      'id': 'aa11bb22',
      'direction': 'sell', 'entry': 4165.0, 'exit': 4164.0, 'qty': 1.0,
      'tp': null, 'sl': null, 'pnl': 1.0,
      'status': 'closed', 'opened_at': '2026-10-06T13:24:00+00:00',
      'closed_at': '2026-10-06T13:26:07+00:00', 'reason': 'Manual close',
    },
  ];
  app.trades = [
    {
      'id': 'b368f376', 'instrument': 'XAU/USD', 'direction': 'sell',
      'entry': 4165, 'exit': 4164, 'pnl': 1, 'tp': null, 'sl': null,
      'note': '', 'traded_at': '2026-10-06T13:25:00+00:00',
    },
  ];
  return app;
}

Future<void> shoot(WidgetTester tester, Widget Function(AppState) make, String name) async {
  final app = demoState();
  if (name == 'positions') {
    app.expanded.add('ed587ff8-0e70-4438-ad78-0989daa653b6');
  }
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: AnimatedBuilder(
      animation: app,
      builder: (_, __) => Scaffold(body: SafeArea(child: make(app))),
    ),
  ));
  await tester.pump();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
    // Deterministic session strip for goldens.
    SessionsStrip.debugNow = () => DateTime.utc(2026, 10, 7, 14, 0);
  });

  testWidgets('trade', (t) async {
    await shoot(t, (app) => TradeTab(app: app, candleLoaderOverride: testCandles), 'trade');
  });
  testWidgets('compact sides keep half-height targets and select without trading', (t) async {
    final app = demoState();
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildAppTheme(), home: Scaffold(body: TradeTab(app: app, candleLoaderOverride: testCandles))));
    await t.pump();
    final sell = find.ancestor(of: find.text('SELL'), matching: find.byType(InkWell)).first;
    expect(t.getSize(sell).height, 52);
    final count = app.positions.length;
    await t.tap(find.text('SELL'));
    await t.pump();
    expect(find.text('SELL (selected)'), findsOneWidget);
    expect(find.text('SELL paper order'), findsOneWidget);
    expect(app.positions.length, count);
    expect(t.takeException(), isNull);
  });
  testWidgets('positions', (t) async {
    await shoot(t, (app) => PositionsTab(app: app), 'positions');
  });
  testWidgets('stats', (t) async {
    await shoot(t, (app) => StatsTab(app: app), 'stats');
  });
}

/// Deterministic synthetic candles for GOLDEN RENDERS ONLY. The app itself
/// never fabricates market data.
Future<List<Candle>> testCandles(String interval) async {
  final rnd = math.Random(42);
  double px = 4100;
  final base = DateTime(2026, 10, 6, 9, 0);
  return List.generate(80, (i) {
    final o = px;
    final c = o + (rnd.nextDouble() - 0.48) * 8;
    final h = math.max(o, c) + rnd.nextDouble() * 3;
    final l = math.min(o, c) - rnd.nextDouble() * 3;
    px = c;
    return Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: o, high: h, low: l, close: c);
  });
}
