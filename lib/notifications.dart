/// Local push notifications (Oro request): TP/SL hits and price alerts
/// while the app is closed.
///
/// Design: no FCM/server. Android WorkManager runs a periodic background
/// check (platform minimum ~15 minutes, OEM battery savers can delay it
/// further - that is the honest limit of server-free background work).
/// Each run fetches the real quote + paper_state and compares against the
/// last-seen open positions and untriggered price alerts stored in
/// SharedPreferences, then posts system notifications.
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'notification_log.dart';

const String bgTaskName = 'oroBackgroundCheck';
const String _channelId = 'oro_alerts';
const String _sbUrl = 'https://ncaialkmxhbtarmhoiei.supabase.co';
// Public anon key (same as the app; RPCs are pin-guarded).
const String _sbKey =
    'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

Future<void> _initPlugin() async {
  const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'));
  await _fln.initialize(init);
  final android = _fln.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(const AndroidNotificationChannel(
    _channelId,
    'Oro alerts',
    description: 'TP/SL hits and price alerts',
    importance: Importance.high,
  ));
}

/// Call once from main() before runApp.
Future<void> initNotifications() async {
  await _initPlugin();
  // Runtime permission (Android 13+). No-op on older versions.
  await _fln
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  await Workmanager().initialize(oroBgDispatcher);
  await Workmanager().registerPeriodicTask(
    bgTaskName,
    bgTaskName,
    frequency: const Duration(minutes: 15), // Android-enforced minimum
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

Future<void> _notify(int id, String title, String body) async {
  // Record every posted notification for the in-app history (bell icon).
  // Also runs in the background worker isolate; SharedPreferences is shared.
  await NotificationLog.add(title, body);
  await _fln.show(
    id,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Oro alerts',
        channelDescription: 'TP/SL hits and price alerts',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

bool _foregroundInitDone = false;

/// Post a system notification from the RUNNING app (price alert triggered
/// while the user is watching, TP/SL seen on refresh, ...). Without this,
/// an alert that fires in the foreground only shows the in-app banner AND
/// gets marked triggered, so the background worker never notifies either.
Future<void> showForegroundNotification(String title, String body) async {
  try {
    if (!_foregroundInitDone) {
      await _initPlugin();
      _foregroundInitDone = true;
    }
    await _notify(DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
        title, body);
  } catch (_) {
    // Plugin unavailable (tests, unsupported platform): banner still shows.
  }
}

@pragma('vm:entry-point')
void oroBgDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await _bgCheck();
    } catch (_) {
      // Never crash the worker; a failed run just retries next cycle.
    }
    return true;
  });
}

class _Quote {
  final double bid;
  final double ask;
  const _Quote(this.bid, this.ask);
  double get mid => (bid + ask) / 2;
}

Future<_Quote?> _fetchQuote() async {
  try {
    final r = await http
        .get(Uri.parse(
            'https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/XAU/USD'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final list = jsonDecode(r.body) as List;
    final prices =
        (list.first as Map)['spreadProfilePrices'] as List? ?? const [];
    if (prices.isEmpty) return null;
    final p = prices.first as Map;
    final bid = (p['bid'] as num?)?.toDouble();
    final ask = (p['ask'] as num?)?.toDouble();
    if (bid == null || ask == null || bid <= 0 || ask <= 0) return null;
    return _Quote(bid, ask);
  } catch (_) {
    return null;
  }
}

/// Close one paper position server-side via the existing paper_close RPC.
/// Returns the decoded response (may carry pnl), or null on failure.
Future<Map<String, dynamic>?> _closePosition(
    String pin, dynamic tid, double price, String why) async {
  try {
    final r = await http
        .post(Uri.parse('$_sbUrl/rest/v1/rpc/paper_close'),
            headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
            body: jsonEncode(
                {'p': pin, 'tid': tid, 'price': price, 'why': why}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) return null;
    final j = jsonDecode(r.body);
    return j is Map<String, dynamic> ? j : const {};
  } catch (_) {
    return null;
  }
}

Future<List<Map<String, dynamic>>> _fetchPositions(String pin) async {
  final r = await http
      .post(Uri.parse('$_sbUrl/rest/v1/rpc/paper_state'),
          headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
          body: jsonEncode({'p': pin}))
      .timeout(const Duration(seconds: 20));
  if (r.statusCode >= 400) return const [];
  final j = jsonDecode(r.body);
  return List<Map<String, dynamic>>.from(j['positions'] as List? ?? []);
}

Future<void> _bgCheck() async {
  await _initPlugin();
  final prefs = await SharedPreferences.getInstance();
  final pin = prefs.getString('tj_pin') ?? '';
  if (pin.isEmpty) return; // not unlocked on this device

  final quote = await _fetchQuote();
  var positions = await _fetchPositions(pin);
  final closedIds = <String>{};

  // --- Auto-close TP/SL (the server never closes positions by itself;
  // the foreground app normally does, so when the app is closed this
  // worker is the only closer). Reads tp/sl from the server position,
  // overlaid with the device-local limits the user edited after opening
  // (same merge as the app's effectiveLimit). Exit-side pricing: a buy
  // is sold at bid, a sell is bought back at ask.
  if (quote != null) {
    Map<String, dynamic> localLimits = const {};
    final limitsRaw = prefs.getString('tj_paper_limits');
    if (limitsRaw != null) {
      try {
        localLimits = Map<String, dynamic>.from(jsonDecode(limitsRaw));
      } catch (_) {}
    }
    double? effLimit(Map<String, dynamic> p, String key) {
      final local = localLimits[p['id'].toString()];
      if (local is Map && local.containsKey(key)) {
        return (local[key] as num?)?.toDouble();
      }
      return (p[key] as num?)?.toDouble();
    }

    var nid = 50;
    for (final p in positions) {
      final buy = p['direction'] == 'buy';
      final mark = buy ? quote.bid : quote.ask;
      final tp = effLimit(p, 'tp');
      final sl = effLimit(p, 'sl');
      String? why;
      String? label;
      if (tp != null && ((buy && mark >= tp) || (!buy && mark <= tp))) {
        why = 'take profit hit at $tp';
        label = 'Take Profit';
      } else if (sl != null && ((buy && mark <= sl) || (!buy && mark >= sl))) {
        why = 'stop loss hit at $sl';
        label = 'Stop Loss Hit';
      }
      if (why == null) continue;
      final res = await _closePosition(pin, p['id'], mark, why);
      if (res == null) continue; // failed - retry next cycle, no notification
      closedIds.add(p['id'].toString());
      final pnl = (res['pnl'] as num?)?.toDouble();
      final pnlTxt = pnl != null
          ? ' · P/L ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}'
          : '';
      await _notify(
          nid++,
          '$label',
          '${buy ? 'Buy' : 'Sell'} XAU/USD ${_qty(p)} closed at ${mark.toStringAsFixed(2)}$pnlTxt');
    }
    if (closedIds.isNotEmpty) {
      positions = await _fetchPositions(pin);
    }
  }

  // --- TP/SL fallback (position disappeared since last check, e.g.
  // closed from another device) ---
  final prevRaw = prefs.getString('tj_bg_positions');
  if (prevRaw != null) {
    try {
      final prev = List<Map<String, dynamic>>.from(jsonDecode(prevRaw));
      final openIds = positions.map((p) => p['id'].toString()).toSet();
      var nid = 1;
      for (final p in prev) {
        final id = p['id'].toString();
        if (openIds.contains(id)) continue;
        if (closedIds.contains(id)) continue; // already notified above
        final dir = p['direction'] == 'buy' ? 'Buy' : 'Sell';
        final tp = (p['tp'] as num?)?.toDouble();
        final sl = (p['sl'] as num?)?.toDouble();
        var why = 'closed';
        final price = quote?.mid;
        if (price != null) {
          if (tp != null &&
              ((p['direction'] == 'buy' && price >= tp) ||
                  (p['direction'] == 'sell' && price <= tp))) {
            why = 'take profit hit at $tp';
          } else if (sl != null &&
              ((p['direction'] == 'buy' && price <= sl) ||
                  (p['direction'] == 'sell' && price >= sl))) {
            why = 'stop loss hit at $sl';
          }
        }
        await _notify(nid++, 'Oro: position closed',
            '$dir XAU/USD ${_qty(p)} - $why');
      }
    } catch (_) {}
  }
  await prefs.setString(
      'tj_bg_positions',
      jsonEncode(positions
          .map((p) => {
                'id': p['id'],
                'direction': p['direction'],
                'qty': p['qty'],
                'tp': p['tp'],
                'sl': p['sl'],
              })
          .toList()));

  // --- Price alerts ---
  final alertPrice = quote?.mid;
  if (alertPrice != null) {
    final price = alertPrice;
    final raw = prefs.getString('tj_price_alerts');
    if (raw != null) {
      try {
        final alerts = List<Map<String, dynamic>>.from(jsonDecode(raw));
        var changed = false;
        var nid = 100;
        for (final a in alerts) {
          if (a['triggered'] == true) continue;
          final level = (a['level'] as num?)?.toDouble();
          if (level == null) continue;
          final above = a['above'] == true;
          final hit = above ? price >= level : price <= level;
          if (!hit) continue;
          a['triggered'] = true;
          a['triggeredAt'] = DateTime.now().toIso8601String();
          changed = true;
          await _notify(nid++, 'Oro: price alert',
              'XAU/USD ${above ? "rose above" : "fell below"} $level (now ${price.toStringAsFixed(2)})');
        }
        if (changed) {
          await prefs.setString('tj_price_alerts', jsonEncode(alerts));
        }
      } catch (_) {}
    }
  }
}

String _qty(Map<String, dynamic> p) =>
    'x${(p['qty'] as num?)?.toStringAsFixed(2) ?? '?'}';
