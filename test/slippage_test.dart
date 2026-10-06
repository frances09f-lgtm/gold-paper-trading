import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/slippage.dart';

void main() {
  test('off by default: no price change', () {
    const s = Slippage('off');
    expect(s.amount, 0);
    expect(s.fill(4150.0, buying: true), 4150.0);
    expect(s.fill(4150.0, buying: false), 4150.0);
  });

  test('low and custom always worsen the fill', () {
    const low = Slippage('low');
    expect(low.fill(4150.0, buying: true), 4150.05);
    expect(low.fill(4150.0, buying: false), 4149.95);
    const c = Slippage('custom', 0.25);
    expect(c.fill(4150.0, buying: true), 4150.25);
    expect(c.fill(4150.0, buying: false), 4149.75);
    const neg = Slippage('custom', -1); // clamped, never helps the trader
    expect(neg.amount, 0);
  });
}
