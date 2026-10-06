import 'dart:math' as math;

/// Stage (d): risk sizing and performance analytics. Pure functions over
/// real closed-trade PnL series - no fabricated data, empty input yields
/// empty output and the UI hides the row.

/// Position size (oz) that risks [riskAmount] if the stop loss is hit.
/// qty = riskAmount / |entry - stop|. Null when inputs are unusable.
double? riskQty(double riskAmount, double entry, double? stop) {
  if (stop == null) return null;
  final dist = (entry - stop).abs();
  if (dist <= 0 || riskAmount <= 0) return null;
  return riskAmount / dist;
}

/// Notional value of a position at entry.
double notional(double qty, double entry) => qty * entry;

/// Gross profit / gross loss. Null when there are no losses (undefined,
/// not infinite - the UI shows '-' rather than a fake number).
double? profitFactor(List<double> pnls) {
  final wins = pnls.where((p) => p > 0).fold<double>(0, (a, b) => a + b);
  final losses = pnls.where((p) => p < 0).fold<double>(0, (a, b) => a - b);
  if (losses <= 0) return null;
  return wins / losses;
}

double? avgOf(Iterable<double> xs) {
  if (xs.isEmpty) return null;
  return xs.fold<double>(0, (a, b) => a + b) / xs.length;
}

/// Peak-to-trough drawdown of the running equity series built from
/// [start] plus cumulative pnls. Returns the max drawdown as a positive
/// dollar amount; 0 when the curve never dips.
double maxDrawdown(double start, List<double> pnlsInTimeOrder) {
  double equity = start;
  double peak = start;
  double maxDd = 0;
  for (final p in pnlsInTimeOrder) {
    equity += p;
    peak = math.max(peak, equity);
    maxDd = math.max(maxDd, peak - equity);
  }
  return maxDd;
}

/// Current streak: positive = consecutive wins, negative = consecutive
/// losses, counting back from the most recent trade. 0 when empty.
int currentStreak(List<double> pnlsInTimeOrder) {
  if (pnlsInTimeOrder.isEmpty) return 0;
  final lastWin = pnlsInTimeOrder.last > 0;
  int n = 0;
  for (final p in pnlsInTimeOrder.reversed) {
    if ((p > 0) != lastWin) break;
    n++;
  }
  return lastWin ? n : -n;
}

/// Total $ at risk across open positions: distance from entry to stop
/// times qty (per position); positions without a stop contribute their
/// full notional exposure instead - they are unprotected.
double openRisk(Iterable<({double entry, double qty, double? stop})> open) {
  double sum = 0;
  for (final t in open) {
    if (t.stop != null && (t.entry - t.stop!).abs() > 0) {
      sum += (t.entry - t.stop!).abs() * t.qty;
    } else {
      sum += t.entry * t.qty;
    }
  }
  return sum;
}
