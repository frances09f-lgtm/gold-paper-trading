import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/market_data/models.dart';
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

  test('medium confidence no longer trades (user: only when sure)', () {
    final d = parseDecision(
        '{"action":"buy","confidence":"medium","stop_loss":3990,"take_profit":4020,"size_pct":10,"reason":"decent setup"}',
        buyRef: 4000, sellRef: 3999);
    expect(d.action, 'buy');
    expect(d.isTrade, isFalse);
  });

  test('AiDecision.hold never trades', () {
    expect(AiDecision.hold('x').isTrade, isFalse);
  });

  test('parseAdvice reads a clean verdict', () {
    final r = parseAdvice('{"verdict":"buy","reasons":"Price holding above support."}');
    expect(r.verdict, 'buy');
    expect(r.reasons, contains('support'));
  });
  
  test('parseAdvice demotes unknown verdicts to wait', () {
    final r = parseAdvice('{"verdict":"moon","reasons":"x"}');
    expect(r.verdict, 'wait');
  });
  
  test('parseAdvice survives garbage', () {
    final r = parseAdvice('not json at all');
    expect(r.verdict, 'wait');
    expect(r.reasons, isNotEmpty);
  });
  
  test('buildAdvicePrompt includes S/R and drawn levels', () {
    final candles = List.generate(
        60,
        (i) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(i * 900000),
              open: 4000 + i.toDouble(),
              high: 4002 + i.toDouble(),
              low: 3998 + i.toDouble(),
              close: 4001 + i.toDouble(),
            ));
    final p = buildAdvicePrompt(bid: 4059.5, ask: 4060.5, candles: candles, drawnLevels: [4010.0, 4044.0]);
    expect(p, contains('resistance'));
    expect(p, contains('support'));
    expect(p, contains('4010.0'));
    expect(p, contains('4044.0'));
  });


  group('Advice sure-trade (v37)', () {
    test('sure directional advice carries clamped TP/SL and trades', () {
      final r = parseAdvice(
          '{"verdict":"buy","confidence":"high","buy_pct":80,"sell_pct":15,'
          '"stop_loss":3000,"take_profit":5000,"size_pct":40,"reasons":"Strong breakout."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isTrue);
      expect(r.sl, 4000 * 0.98); // clamped into 0.3-2.0%
      expect(r.tp! - 4000, greaterThanOrEqualTo(1.5 * (4000 - r.sl!)));
      expect(r.sizePct, 25); // clamped to max
    });
    test('low-confidence direction stays read-only', () {
      final r = parseAdvice(
          '{"verdict":"sell","confidence":"low","stop_loss":4010,"take_profit":3980,"reasons":"Weak."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
      expect(r.sl, isNull);
      expect(r.tp, isNull);
    });
    test('high-confidence wait never trades', () {
      final r = parseAdvice(
          '{"verdict":"wait","confidence":"high","reasons":"Mixed picture."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
      expect(r.sl, isNull);
    });
    test('missing confidence defaults to low (no trade)', () {
      final r = parseAdvice('{"verdict":"buy","reasons":"x"}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
    });
  });

  group('Advice prediction percentages (v36)', () {
    test('buy/sell percentages parse through', () {
      final r = parseAdvice(
          '{"verdict":"buy","buy_pct":62,"sell_pct":38,"reasons":"Support held."}');
      expect(r.verdict, 'buy');
      expect(r.buyPct, 62);
      expect(r.sellPct, 38);
      expect(r.reasons, 'Support held.');
    });
    test('missing percentages stay null so the UI hides them', () {
      final r = parseAdvice('{"verdict":"wait","reasons":"Mixed."}');
      expect(r.buyPct, isNull);
      expect(r.sellPct, isNull);
    });
    test('percentages clamp to 0-100 and must be numeric', () {
      final r = parseAdvice(
          '{"verdict":"sell","buy_pct":-5,"sell_pct":140,"reasons":"x"}');
      expect(r.buyPct, 0);
      expect(r.sellPct, 100);
      final r2 = parseAdvice(
          '{"verdict":"sell","buy_pct":"high","sell_pct":70,"reasons":"x"}');
      expect(r2.buyPct, isNull);
      expect(r2.sellPct, 70);
    });
    test('malformed still degrades to wait with no percentages', () {
      final r = parseAdvice('not json at all');
      expect(r.verdict, 'wait');
      expect(r.buyPct, isNull);
      expect(r.sellPct, isNull);
    });
    test('double percentages round to whole numbers', () {
      final r = parseAdvice(
          '{"verdict":"buy","buy_pct":61.6,"sell_pct":38.2,"reasons":"x"}');
      expect(r.buyPct, 62);
      expect(r.sellPct, 38);
    });
  });
}
