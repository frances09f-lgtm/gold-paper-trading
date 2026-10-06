import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/main.dart';

AppState stateWithSpread() {
  final app = AppState();
  app.unlocked = true;
  app.price = 4153.70; // mid
  app.bid = 4153.35;
  app.ask = 4154.05;
  app.priceAt = DateTime.now().millisecondsSinceEpoch;
  app.priceOk = true;
  return app;
}

void main() {
  test('buy enters at ask, sell enters at bid', () {
    final app = stateWithSpread();
    expect(app.entrySidePrice('buy'), 4154.05);
    expect(app.entrySidePrice('sell'), 4153.35);
  });

  test('buy exits at bid, sell exits at ask', () {
    final app = stateWithSpread();
    expect(app.exitSidePrice('buy'), 4153.35);
    expect(app.exitSidePrice('sell'), 4154.05);
  });

  test('spread is a real cost inside floating PnL', () {
    final app = stateWithSpread();
    // Buy opened at the ask 4154.05; mark-to-exit is the bid 4153.35,
    // so the position is down exactly the spread at entry.
    final t = {'entry': 4154.05, 'qty': 1.0, 'direction': 'buy'};
    expect(app.livePnl(t), closeTo(-0.70, 1e-9));
    final s = {'entry': 4153.35, 'qty': 2.0, 'direction': 'sell'};
    expect(app.livePnl(s), closeTo(-1.40, 1e-9));
  });

  test('falls back to mid when the feed has no spread', () {
    final app = AppState();
    app.unlocked = true;
    app.price = 4153.70;
    app.priceAt = DateTime.now().millisecondsSinceEpoch;
    app.priceOk = true;
    expect(app.entrySidePrice('buy'), 4153.70);
    expect(app.exitSidePrice('sell'), 4153.70);
    expect(app.spread, isNull);
  });

  test('spread getter', () {
    final app = stateWithSpread();
    expect(app.spread, closeTo(0.70, 1e-9));
  });
}
