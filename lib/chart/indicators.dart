import '../market_data/models.dart';

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
    avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss)
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
