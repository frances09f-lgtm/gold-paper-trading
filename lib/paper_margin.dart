/// Local estimate only, not server/broker margin or liquidation accounting.
class PaperMargin {
  static const leverage = 500.0;
  static double? estimate({
    required double balance,
    required double bid,
    required double ask,
    required List<Map<String, dynamic>> positions,
  }) {
    if (!balance.isFinite ||
        !bid.isFinite ||
        !ask.isFinite ||
        bid <= 0 ||
        ask < bid)
      return null;
    var equity = balance, used = 0.0;
    for (final p in positions.where((p) => p['status'] == 'open')) {
      final qty = (p['qty'] as num?)?.toDouble(),
          entry = (p['entry'] as num?)?.toDouble();
      final side = p['direction'];
      if (qty == null ||
          entry == null ||
          !qty.isFinite ||
          qty <= 0 ||
          !entry.isFinite ||
          entry <= 0 ||
          !['buy', 'sell'].contains(side))
        return null;
      equity += (side == 'buy' ? bid - entry : entry - ask) * qty;
      used += ask * qty / leverage;
    }
    return equity - used;
  }

  static String? guard({
    required double? free,
    required double price,
    required double qty,
  }) {
    if (free == null ||
        !price.isFinite ||
        price <= 0 ||
        !qty.isFinite ||
        qty <= 0)
      return 'Cannot estimate paper margin from current account data.';
    final required = price * qty / leverage;
    if (required > free)
      return 'Estimated paper margin insufficient: needs \$${required.toStringAsFixed(2)}, available \$${free.toStringAsFixed(2)} at assumed 1:500. Reduce oz. This is a client estimate, not broker accounting.';
    return null;
  }
}
