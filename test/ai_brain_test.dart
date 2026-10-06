import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/ai_brain.dart';

void main() {
  group('parseDecision', () {
    test('parses a clean buy decision and clamps SL/TP', () {
      final d = parseDecision(
        '{"action":"buy","confidence":"high","stop_loss":3980.0,"take_profit":4050.0,"size_pct":12,"reason":"uptrend with momentum"}',
        buyRef: 4000.0,
        sellRef: 3999.5,
      );
      expect(d.action, 'buy');
      expect(d.confidence, 'high');
      expect(d.isTrade, isTrue);
      expect(d.sl, 3980.0);
      expect(d.tp, 4050.0);
      expect(d.sizePct, 12);
    });

    test('garbage becomes a safe hold', () {
      final d = parseDecision('I think the market looks nice today',
          buyRef: 4000, sellRef: 3999);
      expect(d.action, 'hold');
      expect(d.isTrade, isFalse);
    });

    test('low confidence never trades', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"low","stop_loss":3990,"take_profit":4020,"size_pct":10,"reason":"weak signal"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.isTrade, isFalse);
    });

    test('wild stop loss is clamped into 0.3-2.0%', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3000,"take_profit":5000,"size_pct":50,"reason":"yolo"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.sl, 4000 * 0.98); // clamped to max 2% distance
      expect(d.sizePct, 25); // clamped to max
      expect(d.tp! - 4000, greaterThanOrEqualTo(1.5 * (4000 - d.sl!)));
    });

    test('missing SL/TP gets sane defaults for a sell', () {
      final d = parseDecision(
          '{"action":"sell","confidence":"medium","size_pct":10,"reason":"breakdown"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.sl, closeTo(3999 * 1.006, 0.01));
      expect(d.tp, closeTo(3999 - 1.5 * (3999 * 0.006), 0.01));
    });

    test('wrong-side TP is replaced', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3990,"take_profit":3950,"size_pct":10,"reason":"x"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.tp, greaterThan(4000));
    });
  });

  test('AiDecision.hold never trades', () {
    expect(AiDecision.hold('x').isTrade, isFalse);
  });
}
