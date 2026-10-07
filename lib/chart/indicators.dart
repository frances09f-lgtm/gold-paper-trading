import '../market_data/models.dart';

import 'dart:math' as math;

/// Stage (e): technical indicators over REAL candle closes. Pure functions;
/// shorter series than the period yield shorter (or empty) outputs, never
/// padded or invented values.

/// Simple moving average aligned to the input: output[i] is the SMA ending
/// at candle i+period-1, so it pairs with candles.sublist(period-1).
List<double> sma(List<Candle> candles, int period) {
  if (period <= 0 || candles.length < period) return [];
  final out = <double>[];
  double sum = 0;
  for (int i = 0; i < candles.length; i++) {
    sum += candles[i].close;
    if (i >= period) sum -= candles[i - period].close;
    if (i >= period - 1) out.add(sum / period);
  }
  return out;
}

/// Exponential moving average, seeded with the SMA of the first [period]
/// closes. Same alignment convention as [sma].
List<double> ema(List<Candle> candles, int period) {
  if (period <= 0 || candles.length < period) return [];
  final k = 2 / (period + 1);
  double prev =
      candles.sublist(0, period).fold<double>(0, (a, c) => a + c.close) /
      period;
  final out = <double>[prev];
  for (int i = period; i < candles.length; i++) {
    prev = candles[i].close * k + prev * (1 - k);
    out.add(prev);
  }
  return out;
}

/// Wilder RSI. Returns values aligned with candles.sublist(period), i.e.
/// output has candles.length - period entries.
List<double> rsi(List<Candle> candles, int period) {
  if (period <= 0 || candles.length <= period) return [];
  double gain = 0, loss = 0;
  for (int i = 1; i <= period; i++) {
    final d = candles[i].close - candles[i - 1].close;
    if (d > 0) {
      gain += d;
    } else {
      loss -= d;
    }
  }
  double avgGain = gain / period, avgLoss = loss / period;
  final out = <double>[
    avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss),
  ];
  for (int i = period + 1; i < candles.length; i++) {
    final d = candles[i].close - candles[i - 1].close;
    final g = d > 0 ? d : 0.0;
    final l = d < 0 ? -d : 0.0;
    avgGain = (avgGain * (period - 1) + g) / period;
    avgLoss = (avgLoss * (period - 1) + l) / period;
    out.add(avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss));
  }
  return out;
}

/// MACD (12/26/9) over real closes. macdLine[i] pairs with candles[25+i];
/// signal[i] and hist[i] pair with candles[33+i]. Shorter inputs yield
/// shorter (or empty) outputs, never padded or invented values.
(List<double> line, List<double> signal, List<double> hist) macd(
  List<Candle> candles,
) {
  final e12 = ema(candles, 12);
  final e26 = ema(candles, 26);
  if (e26.isEmpty) return (const [], const [], const []);
  // e12[i] pairs with candle 11+i, e26[j] with candle 25+j, so for candle
  // 25+j the e12 index is 14+j.
  final line = <double>[
    for (int j = 0; j < e26.length; j++) e12[j + 14] - e26[j],
  ];
  if (line.length < 9) return (line, const [], const []);
  const k = 2 / 10;
  double prev = line.sublist(0, 9).fold<double>(0, (a, b) => a + b) / 9;
  final signal = <double>[prev];
  for (int i = 9; i < line.length; i++) {
    prev = line[i] * k + prev * (1 - k);
    signal.add(prev);
  }
  final hist = <double>[
    for (int i = 0; i < signal.length; i++) line[i + 8] - signal[i],
  ];
  return (line, signal, hist);
}

/// Population standard deviation bands, aligned with SMA(period).
(List<double> middle, List<double> upper, List<double> lower) bollinger(
  List<Candle> candles, {
  int period = 20,
  double deviations = 2,
}) {
  final middle = sma(candles, period);
  final upper = <double>[], lower = <double>[];
  for (var i = 0; i < middle.length; i++) {
    final mean = middle[i];
    double variance = 0;
    for (var j = i; j < i + period; j++) {
      final d = candles[j].close - mean;
      variance += d * d;
    }
    final width = deviations * math.sqrt(variance / period);
    upper.add(mean + width);
    lower.add(mean - width);
  }
  return (middle, upper, lower);
}
