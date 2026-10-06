import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/analytics.dart';

void main() {
  test('riskQty sizes from stop distance', () {
    expect(riskQty(100, 4150, 4140), closeTo(10, 1e-9)); // $100 / $10 = 10oz
    expect(riskQty(100, 4150, 4150), isNull); // zero distance
    expect(riskQty(100, 4150, null), isNull);
    expect(riskQty(0, 4150, 4140), isNull);
  });

  test('profitFactor is gross wins over gross losses, null without losses', () {
    expect(profitFactor([10, -5, 20, -5]), closeTo(3.0, 1e-9));
    expect(profitFactor([10, 20]), isNull);
    expect(profitFactor([]), isNull);
  });

  test('maxDrawdown tracks peak-to-trough of running equity', () {
    expect(maxDrawdown(100, [10, -30, 5]), 30); // peak 110, trough 80
    expect(maxDrawdown(100, [5, 5]), 0);
    expect(maxDrawdown(100, []), 0);
  });

  test('currentStreak signs wins positive, losses negative', () {
    expect(currentStreak([1, 2, -1, -2]), -2);
    expect(currentStreak([-1, 1, 1, 1]), 3);
    expect(currentStreak([]), 0);
  });

  test('openRisk uses stop distance, notional when unprotected', () {
    final risk = openRisk([
      (entry: 100.0, qty: 2.0, stop: 95.0), // 5 * 2 = 10
      (entry: 100.0, qty: 1.0, stop: null), // notional 100
    ]);
    expect(risk, closeTo(110, 1e-9));
  });
}
