import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Device-local snapshot. Quote and account freshness are independent.
/// Missing account data is unknown, never proof there are no positions.
class OroBridge {
  static const snapshotKey = 'oro_bridge_snapshot';

  static void noteQuote(
    SharedPreferences? prefs,
    double? bid,
    double? ask,
    int tsMs,
  ) {
    if (prefs == null) return;
    final snapshot = _read(prefs);
    if (bid != null &&
        ask != null &&
        bid.isFinite &&
        ask.isFinite &&
        bid > 0 &&
        ask > 0) {
      snapshot.addAll({'bid': bid, 'ask': ask, 'quoteAt': tsMs});
    }
    _mergeAccount(prefs, snapshot);
    _write(prefs, snapshot);
  }

  static void notePaper(SharedPreferences? prefs) {
    if (prefs == null) return;
    final snapshot = _read(prefs);
    _mergeAccount(prefs, snapshot);
    _write(prefs, snapshot);
  }

  static Map<String, dynamic> _read(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(snapshotKey);
      if (raw != null) return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    return {};
  }

  static void _mergeAccount(
    SharedPreferences prefs,
    Map<String, dynamic> snapshot,
  ) {
    try {
      final raw = prefs.getString('tj_paper_cache');
      if (raw == null) return;
      final account = jsonDecode(raw) as Map;
      if (account['positions'] is! List) return;
      snapshot.addAll({
        'accountKnown': true,
        'accountAt': (account['accountAt'] as num?)?.toInt() ?? 0,
        'balance': account['balance'],
        'open': (account['positions'] as List)
            .whereType<Map>()
            .where((p) => p['status'] == 'open')
            .map(
              (p) => {
                'dir': p['direction'],
                'qty': p['qty'],
                'entry': p['entry'],
                'tp': p['tp'],
                'sl': p['sl'],
              },
            )
            .toList(),
      });
    } catch (_) {}
  }

  static void _write(SharedPreferences prefs, Map<String, dynamic> snapshot) {
    snapshot['ts'] = DateTime.now().millisecondsSinceEpoch;
    snapshot.putIfAbsent('accountKnown', () => false);
    snapshot.putIfAbsent('accountAt', () => 0);
    snapshot.putIfAbsent('open', () => <dynamic>[]);
    prefs.setString(snapshotKey, jsonEncode(snapshot));
  }
}
