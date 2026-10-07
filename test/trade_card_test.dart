import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/trade_card.dart';

void main() {
  test('buy risk in USD is stop distance times oz', () {
    const d = TradeExplanation(
      entry: 3000,
      qty: 2,
      buy: true,
      stop: 2995,
      target: 3010,
      spread: 0.7,
    );
    expect(d.risk, 10);
    expect(d.stopDistance, 5);
    expect(d.reward, 20);
    expect(d.targetDistance, 10);
  });
  test('sell uses inverse outcome', () {
    const d = TradeExplanation(
      entry: 3000,
      qty: 2,
      buy: false,
      stop: 3005,
      target: 2990,
    );
    expect(d.risk, 10);
    expect(d.reward, 20);
  });
  test('profit-locking stop not loss risk', () {
    const d = TradeExplanation(entry: 3000, qty: 2, buy: true, stop: 3005);
    expect(d.risk, 0);
    expect(d.stopProtects, false);
  });
  test('no stop never guesses risk', () {
    const d = TradeExplanation(entry: 3000, qty: 2, buy: true);
    expect(d.risk, isNull);
    expect(d.stopDistance, isNull);
    expect(d.spread, isNull);
  });
  test('loss-side target not called reward', () {
    const d = TradeExplanation(entry: 3000, qty: 2, buy: false, target: 3005);
    expect(d.reward, -10);
  });
}
