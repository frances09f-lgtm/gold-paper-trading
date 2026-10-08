/// Summary of the displayed closed-trade slice, never account balance or
/// floating P/L. Missing/invalid P/L keeps the total explicitly partial.
class HistorySummary {
  final double total;
  final int known, missing;
  const HistorySummary(this.total, this.known, this.missing);
  factory HistorySummary.from(List<Map<String, dynamic>> trades) {
    var total = 0.0, known = 0, missing = 0;
    for (final t in trades) {
      final v = t['pnl'];
      if (v is num && v.toDouble().isFinite) {
        total += v.toDouble();
        known++;
      } else {
        missing++;
      }
    }
    return HistorySummary(total, known, missing);
  }
}
