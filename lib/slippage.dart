/// Spec 21: optional configurable paper-trading slippage. Off by default.
/// Applied to FILL prices only (entry and exit fills), never to displayed
/// market prices. Slippage always makes the fill worse for the trader.
class Slippage {
  final String mode; // 'off' | 'low' | 'custom'
  final double custom; // $ per oz, used when mode == 'custom'

  const Slippage(this.mode, [this.custom = 0]);

  static const lowAmount = 0.05; // $ per oz

  double get amount {
    if (mode == 'low') return lowAmount;
    if (mode == 'custom') return custom < 0 ? 0 : custom;
    return 0;
  }

  /// Fill price with slippage applied. Buys fill higher, sells fill lower.
  double fill(double px, {required bool buying}) =>
      buying ? px + amount : px - amount;

  String get label {
    if (mode == 'low') return 'Low (\$${lowAmount.toStringAsFixed(2)})';
    if (mode == 'custom') return 'Custom (\$${custom.toStringAsFixed(2)})';
    return 'Off';
  }
}
