import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/chart/indicators.dart';
import 'package:gold_paper_trading/market_data/models.dart';

List<Candle> cs(List<double> closes) {
  final base = DateTime(2026, 1, 1);
  return List.generate(
    closes.length,
    (i) => Candle(
      time: base.add(Duration(minutes: i)),
      open: closes[i],
      high: closes[i],
      low: closes[i],
      close: closes[i],
    ),
  );
}

void main() {
  test('bollinger population bands and alignment', () {
    final b = bollinger(cs([1, 2, 3, 4, 5]), period: 3);
    expect(b.$1, [2, 3, 4]);
    expect(b.$2.first, closeTo(3.6329931619, 1e-8));
    expect(b.$3.first, closeTo(0.3670068381, 1e-8));
    expect(bollinger(cs([1, 2])).$1, isEmpty);
  });
  test('EMA periods do not pad missing history', () {
    for (final p in [9, 21, 50, 200]) {
      expect(ema(cs(List.filled(p - 1, 100)), p), isEmpty);
      expect(ema(cs(List.filled(p, 100)), p), [100]);
    }
  });

  test('sma computes and aligns', () {
    final v = sma(cs([1, 2, 3, 4, 5]), 3);
    expect(v, [2.0, 3.0, 4.0]);
    expect(sma(cs([1, 2]), 3), isEmpty);
  });

  test('ema seeds with sma then smooths', () {
    final v = ema(cs([1, 2, 3, 4, 5]), 3);
    expect(v.length, 3);
    expect(v.first, 2.0); // SMA seed
    expect(v.last, closeTo(4.0, 1e-9)); // k=0.5: seed 2 -> 3 -> 4
  });

  test('rsi bounds and all-gains edge', () {
    final up = cs(List.generate(20, (i) => 100.0 + i));
    final v = rsi(up, 14);
    expect(v.length, 6);
    expect(v.every((x) => x > 99), isTrue); // monotonic up -> RSI ~100
    expect(rsi(cs([1, 2, 3]), 14), isEmpty);
  });

  test('rsi mid value for symmetric series', () {
    // Alternating equal gains/losses -> RS = 1 -> RSI = 50
    final alt = cs(List.generate(31, (i) => i.isEven ? 100.0 : 101.0));
    final v = rsi(alt, 14);
    expect(v.last, closeTo(50, 5));
  });
}
