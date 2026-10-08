import 'package:flutter/material.dart';

/// Explanations of this app's implemented paper-trading math, not broker terms.
class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});
  static const lessons = <(String, String)>[
    (
      'Oz is size, not profit',
      'For a buy, gross P/L = (exit - entry) x oz. For a sell, gross P/L = (entry - exit) x oz. A \$3 price move at 1 oz is \$3; at 0.01 oz it is \$0.03. The TP/SL chips move the price per oz, not your total profit.',
    ),
    (
      'Bid, ask and spread',
      'Buy enters at ask and exits at bid. Sell enters at bid and exits at ask. Spread = ask - bid. With bid 4120 and ask 4120.70, a newly opened 1 oz trade starts about \$0.70 down if closed immediately, before any additional costs. Quotes need to be fresh.',
    ),
    (
      'TP and SL are price levels',
      'Take profit (TP) and stop loss (SL) are exit price levels. Projected P/L uses your entry and oz size. Buy TP is above entry, sell TP below. A trigger is not a guaranteed fill: stale quotes, connection failures and slippage can change the outcome.',
    ),
    (
      'Estimated leverage and margin',
      'Sona currently assumes 1:500 for its client paper estimate. Estimated margin = price x oz / 500. At 4120 and 1 oz, that is \$8.24. Leverage does not multiply the \$3 profit of a \$3 move at 1 oz; it lowers the estimated margin for that size. It also makes larger exposure easier and losses can exceed margin.',
    ),
    (
      'Available margin is an estimate',
      'The local guard uses refreshed balance plus floating P/L, minus estimated margin for all open positions. Pending orders reserve no margin and recheck at fill. This is not server or broker accounting, has no liquidation model, and can race across devices. The server may reject the order.',
    ),
    (
      'Saved data is not live data',
      'A chart candle, quote and account snapshot can each have a different age. Read their timestamps. Explain chart uses a saved snapshot and can be wrong; it never changes a trade. Paper results do not promise real-market execution or profit.',
    ),
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Learn paper trading')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Short lessons about Sona\'s paper model. Educational only, not financial advice.',
          ),
        ),
        for (final lesson in lessons)
          Card(
            child: ExpansionTile(
              title: Text(
                lesson.$1,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [Text(lesson.$2)],
            ),
          ),
      ],
    ),
  );
}
