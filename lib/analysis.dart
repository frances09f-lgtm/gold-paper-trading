import 'chart/indicators.dart';
import 'market_data/models.dart';

/// Rule-based "trend bias" read of the CURRENT chart data.
///
/// Every factor is computed from real candles / indicators / user-drawn
/// levels already shown on the chart. There are no price targets, no
/// forecasts and no prediction language - the result says only what the
/// data currently looks like, with each contributing reason listed.
enum TrendBias { bullish, bearish, neutral }

class BiasFactor {
  final int score; // -1 bearish, 0 neutral, +1 bullish
  final String text;
  const BiasFactor(this.score, this.text);
}

class BiasResult {
  final TrendBias bias;
  final int score;
  final List<BiasFactor> factors;
  const BiasResult(this.bias, this.score, this.factors);
}

BiasResult analyzeBias(List<Candle> candles, List<double> drawnLevels) {
  final factors = <BiasFactor>[];
  if (candles.length < 50) {
    return const BiasResult(TrendBias.neutral, 0, [
      BiasFactor(0, 'Not enough candles loaded for a reliable read'),
    ]);
  }
  final price = candles.last.close;

  // 1. Price vs SMA 20
  final s20 = sma(candles, 20);
  if (s20.isNotEmpty) {
    final v = s20.last;
    if (price > v) {
      factors.add(BiasFactor(1, 'Price above SMA 20 (${v.toStringAsFixed(1)})'));
    } else if (price < v) {
      factors.add(BiasFactor(-1, 'Price below SMA 20 (${v.toStringAsFixed(1)})'));
    }
  }

  // 2. SMA 20 vs EMA 50 alignment
  final e50 = ema(candles, 50);
  if (s20.isNotEmpty && e50.isNotEmpty) {
    if (s20.last > e50.last) {
      factors.add(const BiasFactor(1, 'SMA 20 above EMA 50 - trend alignment up'));
    } else if (s20.last < e50.last) {
      factors.add(const BiasFactor(-1, 'SMA 20 below EMA 50 - trend alignment down'));
    }
  }

  // 3. RSI 14 momentum
  final r14 = rsi(candles, 14);
  if (r14.isNotEmpty) {
    final v = r14.last;
    if (v > 55) {
      factors.add(BiasFactor(1, 'RSI 14 at ${v.toStringAsFixed(0)} - momentum positive'));
    } else if (v < 45) {
      factors.add(BiasFactor(-1, 'RSI 14 at ${v.toStringAsFixed(0)} - momentum negative'));
    } else {
      factors.add(BiasFactor(0, 'RSI 14 at ${v.toStringAsFixed(0)} - neutral'));
    }
  }

  // 4. Recent structure: last 10 candles vs the previous 10
  final n = candles.length;
  final last = candles.sublist(n - 10);
  final prev = candles.sublist(n - 20, n - 10);
  double hiOf(List<Candle> cs) => cs.fold(-double.infinity, (a, c) => a > c.high ? a : c.high);
  double loOf(List<Candle> cs) => cs.fold(double.infinity, (a, c) => a < c.low ? a : c.low);
  final hh = hiOf(last) > hiOf(prev);
  final hl = loOf(last) > loOf(prev);
  final lh = hiOf(last) < hiOf(prev);
  final ll = loOf(last) < loOf(prev);
  if (hh && hl) {
    factors.add(const BiasFactor(1, 'Recent structure: higher highs and higher lows'));
  } else if (lh && ll) {
    factors.add(const BiasFactor(-1, 'Recent structure: lower highs and lower lows'));
  } else {
    factors.add(const BiasFactor(0, 'Recent structure: mixed'));
  }

  // 5. User-drawn support/resistance lines
  if (drawnLevels.isNotEmpty) {
    double? support, resistance;
    for (final l in drawnLevels) {
      if (l < price && (support == null || l > support)) support = l;
      if (l > price && (resistance == null || l < resistance)) resistance = l;
    }
    final near = price * 0.003; // within 0.3% counts as "near"
    if (support != null && price - support <= near) {
      factors.add(BiasFactor(1, 'Near your support line at ${support.toStringAsFixed(1)}'));
    }
    if (resistance != null && resistance - price <= near) {
      factors.add(BiasFactor(-1, 'Near your resistance line at ${resistance.toStringAsFixed(1)}'));
    }
  }

  var score = 0;
  for (final f in factors) {
    score += f.score;
  }
  final bias = score >= 2
      ? TrendBias.bullish
      : score <= -2
          ? TrendBias.bearish
          : TrendBias.neutral;
  return BiasResult(bias, score, factors);
}
