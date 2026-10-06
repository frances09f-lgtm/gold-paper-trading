import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/analysis.dart';
import 'package:gold_paper_trading/market_data/models.dart';

List<Candle> trending(int n, {required bool up}) {
  double px = 4000;
  final base = DateTime(2026, 10, 1);
  return List.generate(n, (i) {
    final o = px;
    final c = up ? o + 5 : o - 5;
    px = c;
    return Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: o,
        high: (o > c ? o : c) + 1,
        low: (o < c ? o : c) - 1,
        close: c);
  });
}

void main() {
  test('uptrend reads bullish with reasons', () {
    final r = analyzeBias(trending(80, up: true), const []);
    expect(r.bias, TrendBias.bullish);
    expect(r.score, greaterThanOrEqualTo(2));
    expect(r.factors, isNotEmpty);
  });

  test('downtrend reads bearish', () {
    final r = analyzeBias(trending(80, up: false), const []);
    expect(r.bias, TrendBias.bearish);
  });

  test('too few candles stays neutral, honestly', () {
    final r = analyzeBias(trending(30, up: true), const []);
    expect(r.bias, TrendBias.neutral);
    expect(r.factors.single.text, contains('Not enough'));
  });

  test('drawn resistance above price adds a bearish factor when near', () {
    final cs = trending(80, up: true);
    final price = cs.last.close;
    final r = analyzeBias(cs, [price + price * 0.001]);
    expect(r.factors.any((f) => f.text.contains('resistance')), isTrue);
  });
}
