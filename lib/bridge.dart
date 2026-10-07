import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Offline bridge for Friday (user project: connect the apps,
/// offline-first). Writes the latest REAL snapshot - quote, paper balance,
/// open positions - into SharedPreferences, which the native
/// OroBridgeProvider serves to Friday on the same phone with no network
/// at all. Nothing here invents data: every field comes from the live
/// quote fetch or the paper-state cache, the quote timestamp travels with
/// it so Friday can say how old the numbers are, and stale data is for
/// Friday to disclose, never paper over.
class OroBridge {
  static const snapshotKey = 'oro_bridge_snapshot';

  static double? _bid;
  static double? _ask;
  static int _quoteAtMs = 0;

  /// Newest real quote from fetchPrice() or the background worker.
  static void noteQuote(
      SharedPreferences? prefs, double? bid, double? ask, int tsMs) {
    if (bid != null && ask != null && bid > 0 && ask > 0) {
      _bid = bid;
      _ask = ask;
      _quoteAtMs = tsMs;
    }
    _write(prefs);
  }

  /// Paper account changed (paperRefresh) - rewrite with fresh positions.
  static void notePaper(SharedPreferences? prefs) => _write(prefs);

  static void _write(SharedPreferences? prefs) {
    if (prefs == null) return;
    double? balance;
    List<Map<String, dynamic>> open = [];
    try {
      final raw = prefs.getString('tj_paper_cache');
      if (raw != null) {
        final j = jsonDecode(raw);
        balance = (j['balance'] as num?)?.toDouble();
        open = (j['positions'] as List? ?? [])
            .where((p) => p is Map && p['status'] == 'open')
            .map((p) => {
                  'dir': p['direction'],
                  'qty': p['qty'],
                  'entry': p['entry'],
                  'tp': p['tp'],
                  'sl': p['sl'],
                })
            .toList();
      }
    } catch (_) {}
    prefs.setString(
        snapshotKey,
        jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'bid': _bid,
          'ask': _ask,
          'quoteAt': _quoteAtMs,
          'balance': balance,
          'open': open,
        }));
  }
}
