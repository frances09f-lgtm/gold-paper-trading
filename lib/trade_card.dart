import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Read-only paper-position explanation. All distances are entry-based USD/oz.
class TradeExplanation {
  final double entry, qty;
  final bool buy;
  final double? stop, target, spread;
  const TradeExplanation({
    required this.entry,
    required this.qty,
    required this.buy,
    this.stop,
    this.target,
    this.spread,
  });
  double? get stopDistance => stop == null ? null : (entry - stop!).abs();
  double? get targetDistance => target == null ? null : (target! - entry).abs();
  double? get stopOutcome =>
      stop == null ? null : (stop! - entry) * (buy ? 1 : -1) * qty;
  double? get risk => stopOutcome == null ? null : math.max(0, -stopOutcome!);
  bool get stopProtects => stopOutcome != null && stopOutcome! < 0;
  double? get reward =>
      target == null ? null : (target! - entry) * (buy ? 1 : -1) * qty;
}

class TradeExplanationCard extends StatelessWidget {
  final TradeExplanation data;
  final bool fresh;
  final bool historical;
  const TradeExplanationCard({
    super.key,
    required this.data,
    required this.fresh,
    this.historical = false,
  });
  String f(double? v) => v == null ? 'Not set' : v.toStringAsFixed(2);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Trade card · paper USD',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text('Entry: \$${f(data.entry)} · ${f(data.qty)} oz'),
        Text(
          'SL distance: ${f(data.stopDistance)} USD/oz · TP distance: ${f(data.targetDistance)} USD/oz',
        ),
        Text(
          data.stop == null
              ? 'Risk: unprotected (no stop loss)'
              : data.stopProtects
              ? 'Risk at SL: \$${f(data.risk)}'
              : 'SL locks a gain or break-even; loss at SL: \$0.00',
        ),
        if (data.reward != null)
          Text(
            data.reward! >= 0
                ? 'Outcome at TP: +\$${f(data.reward)}'
                : 'TP is on the loss side: -\$${f(data.reward!.abs())}',
          ),
        Text(
          data.spread == null
              ? (historical
                    ? 'Spread at entry: not recorded'
                    : 'Spread: unavailable (mid-only quote)')
              : data.spread! < 0
              ? 'Spread: invalid quote'
              : 'Spread now: ${f(data.spread)} USD/oz${fresh ? '' : ' (stale quote)'}',
        ),
        const Text(
          'Distances from entry. Outcomes exclude extra slippage/fees.',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    ),
  );
}
