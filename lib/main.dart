import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';
import 'market_data/swissquote_provider.dart';
import 'chart/candle_chart.dart';
import 'analytics.dart';
import 'alerts.dart';
import 'notifications.dart';

const String sbUrl = 'https://ncaialkmxhbtarmhoiei.supabase.co';
const String sbKey = 'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';

const cBg = Color(0xFF0F1115);
const cCard = Color(0xFF171A21);
const cBorder = Color(0xFF232834);
const cDim = Color(0xFF8A93A5);
const cGreen = Color(0xFF2ECC71);
const cRed = Color(0xFFFF5A5F);

String fmt(num? n, {bool sign = false}) {
  if (n == null) return '-';
  final s = n.toStringAsFixed(2);
  return (sign && n > 0 ? '+' : '') + s;
}

String money(num? n, {bool sign = false}) {
  if (n == null) return '-';
  final neg = n < 0;
  final s = (neg ? '-' : (sign && n > 0 ? '+' : '')) + '\$' + fmt(n.abs());
  return s;
}

Color cls(num? n) => n == null ? cDim : (n > 0 ? cGreen : (n < 0 ? cRed : cDim));

class RpcException implements Exception {
  final String message;
  final bool badPin;
  RpcException(this.message, this.badPin);
  @override
  String toString() => message;
}

class AppState extends ChangeNotifier {
  String pin = '';
  bool unlocked = false;
  String lockError = '';
  bool unlocking = false;

  double? price; // mid (display / chart)
  double? bid; // real bid, when the feed provides it
  double? ask; // real ask, when the feed provides it
  int priceAt = 0;
  bool priceOk = false;

  /// Stage (c): execution prices. Buys open at ASK and close at BID;
  /// sells open at BID and close at ASK. Spread is a real trading cost,
  /// so it must be inside entry/exit prices and therefore inside PnL.
  /// Falls back to the single mid price when the feed has no spread.
  double? entrySidePrice(String dir) {
    if (dir == 'buy') return ask ?? price;
    return bid ?? price;
  }

  double? exitSidePrice(String dir) {
    if (dir == 'buy') return bid ?? price;
    return ask ?? price;
  }

  double? get spread =>
      (bid != null && ask != null) ? ask! - bid! : null;
  bool get priceFresh =>
      priceOk && DateTime.now().millisecondsSinceEpoch - priceAt < 5 * 60 * 1000;

  double starting = 10000;
  double balance = 10000;
  List<Map<String, dynamic>> positions = [];
  List<Map<String, dynamic>> trades = [];
  Map<String, Map<String, double?>> limits = {};

  final Set<String> closing = {};
  final Set<String> expanded = {};

  /// Stage (e): journal notes on paper trades. Device-local because the
  /// backend contract has no note field for paper positions.
  Map<String, String> tradeNotes = {};

  void setTradeNote(String tradeId, String note) {
    if (note.trim().isEmpty) {
      tradeNotes.remove(tradeId);
    } else {
      tradeNotes[tradeId] = note.trim();
    }
    prefs?.setString('tj_trade_notes', jsonEncode(tradeNotes));
    notifyListeners();
  }

  /// Stage (e): device-local price alerts, checked on each real quote.
  List<PriceAlert> alerts = [];
  PriceAlert? alertBanner; // most recent trigger, cleared on dismiss

  void _saveAlerts() {
    prefs?.setString('tj_price_alerts',
        jsonEncode(alerts.map((a) => a.toJson()).toList()));
  }

  void addAlert(double level, bool above) {
    alerts.add(PriceAlert(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      level: level,
      above: above,
      createdAt: DateTime.now(),
    ));
    _saveAlerts();
    notifyListeners();
  }

  void removeAlert(String id) {
    alerts.removeWhere((a) => a.id == id);
    _saveAlerts();
    notifyListeners();
  }

  void dismissAlertBanner() {
    alertBanner = null;
    notifyListeners();
  }

  void _checkAlerts() {
    if (price == null || !priceOk) return;
    for (final a in alerts) {
      if (a.check(price!)) {
        alertBanner = a;
        _saveAlerts();
      }
    }
    if (alertBanner != null) notifyListeners();
  }

  Timer? _priceTimer;
  Timer? _ticker;
  SharedPreferences? prefs;

  double? effectiveLimit(Map<String, dynamic> t, String key) {
    final local = limits[t['id'].toString()];
    if (local != null && local.containsKey(key)) return local[key];
    final v = t[key];
    return v == null ? null : (v as num).toDouble();
  }

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    pin = prefs?.getString('tj_pin') ?? '';
    final raw = prefs?.getString('tj_paper_limits');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        m.forEach((k, v) {
          limits[k] = {};
          (v as Map<String, dynamic>).forEach((k2, v2) {
            limits[k]![k2] = v2 == null ? null : (v2 as num).toDouble();
          });
        });
      } catch (_) {}
    }
    final rawNotes = prefs?.getString('tj_trade_notes');
    if (rawNotes != null) {
      try {
        tradeNotes = Map<String, String>.from(jsonDecode(rawNotes) as Map);
      } catch (_) {}
    }
    final rawAlerts = prefs?.getString('tj_price_alerts');
    if (rawAlerts != null) {
      try {
        alerts = (jsonDecode(rawAlerts) as List)
            .map((e) => PriceAlert.fromJson(Map<String, dynamic>.from(e)))
            .whereType<PriceAlert>()
            .toList();
      } catch (_) {}
    }
    final cache = prefs?.getString('tj_paper_cache');
    if (cache != null) {
      try {
        final m = jsonDecode(cache) as Map<String, dynamic>;
        starting = (m['starting'] as num?)?.toDouble() ?? starting;
        balance = (m['balance'] as num?)?.toDouble() ?? balance;
        positions =
            List<Map<String, dynamic>>.from(m['positions'] as List? ?? []);
      } catch (_) {}
    }
    fetchPrice();
    _priceTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (unlocked) fetchPrice();
    });
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (unlocked) notifyListeners();
    });
    if (pin.isNotEmpty) await unlock(pin);
  }

  void _saveLimits() {
    prefs?.setString('tj_paper_limits', jsonEncode(limits));
  }

  void setLimit(String tid, String key, double? value) {
    limits[tid] = {...(limits[tid] ?? {}), key: value};
    _saveLimits();
    notifyListeners();
  }

  Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    final r = await http
        .post(Uri.parse('$sbUrl/rest/v1/rpc/$fn'),
            headers: {'apikey': sbKey, 'Content-Type': 'application/json'},
            body: jsonEncode(args))
        .timeout(const Duration(seconds: 20));
    dynamic j;
    try {
      j = jsonDecode(r.body);
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      final m = (j is Map && j['message'] != null)
          ? j['message'].toString()
          : 'Request failed';
      throw RpcException(m, m.toLowerCase().contains('bad pin'));
    }
    return j;
  }

  Future<bool> unlock(String p) async {
    unlocking = true;
    lockError = '';
    notifyListeners();
    try {
      final list = await rpc('j_list', {'p': p});
      trades = List<Map<String, dynamic>>.from(list as List);
      pin = p;
      unlocked = true;
      await prefs?.setString('tj_pin', p);
      await paperRefresh();
      unlocking = false;
      notifyListeners();
      return true;
    } on RpcException catch (e) {
      unlocking = false;
      lockError = e.badPin ? 'Wrong PIN' : 'Cannot connect. Check internet.';
      if (e.badPin) await prefs?.remove('tj_pin');
      notifyListeners();
      return false;
    } catch (_) {
      unlocking = false;
      lockError = 'Cannot connect. Check internet.';
      notifyListeners();
      return false;
    }
  }

  Future<void> lock() async {
    unlocked = false;
    pin = '';
    await prefs?.remove('tj_pin');
    notifyListeners();
  }

  Future<void> fetchPrice() async {
    // Stage (c): primary source is the Swissquote public BBO feed with a
    // real bid/ask spread. Mid-only feeds remain as fallback.
    try {
      final q = await SwissquoteQuoteProvider().fetchQuote(Instrument.xauUsd);
      bid = q.bid;
      ask = q.ask;
      price = q.mid;
      priceAt = q.ts.millisecondsSinceEpoch;
      priceOk = true;
      notifyListeners();
      checkTpsl();
      _checkAlerts();
      return;
    } catch (_) {}
    Future<({double p, int t})?> trySource(int which) async {
      try {
        if (which == 0) {
          final r = await http
              .get(Uri.parse('https://api.gold-api.com/price/XAU'))
              .timeout(const Duration(seconds: 10));
          final j = jsonDecode(r.body);
          final p = (j['price'] as num).toDouble();
          final t = DateTime.tryParse(j['updatedAt']?.toString() ?? '')
                  ?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch;
          return (p: p, t: t);
        } else {
          final r = await http
              .get(Uri.parse('https://data-asg.goldprice.org/dbXRates/USD'))
              .timeout(const Duration(seconds: 10));
          final j = jsonDecode(r.body);
          final p = (j['items'][0]['xauPrice'] as num).toDouble();
          return (p: p, t: DateTime.now().millisecondsSinceEpoch);
        }
      } catch (_) {
        return null;
      }
    }

    for (final w in [0, 1]) {
      final q = await trySource(w);
      if (q != null && q.p > 0) {
        price = q.p;
        bid = q.p;
        ask = q.p;
        priceAt = q.t;
        priceOk = true;
        notifyListeners();
        checkTpsl();
        _checkAlerts();
        return;
      }
    }
    priceOk = false;
    notifyListeners();
  }

  Future<void> paperRefresh() async {
    if (!unlocked) return;
    try {
      final s = await rpc('paper_state', {'p': pin});
      starting = (s['starting'] as num).toDouble();
      balance = (s['balance'] as num).toDouble();
      positions = List<Map<String, dynamic>>.from(s['positions'] as List? ?? []);
      notifyListeners();
      // Stage (d): device-local cache so the app opens with last-known
      // state while offline; the network refresh above always wins.
      prefs?.setString('tj_paper_cache', jsonEncode({
        'starting': starting,
        'balance': balance,
        'positions': positions,
      }));
    } on RpcException catch (e) {
      if (e.badPin) lock();
    } catch (_) {}
  }

  Future<void> refreshTrades() async {
    if (!unlocked) return;
    try {
      final list = await rpc('j_list', {'p': pin});
      trades = List<Map<String, dynamic>>.from(list as List);
      notifyListeners();
    } on RpcException catch (e) {
      if (e.badPin) lock();
    } catch (_) {}
  }

  double? livePnl(Map<String, dynamic> t) {
    if (!priceOk || price == null) return null;
    final entry = (t['entry'] as num).toDouble();
    final qty = (t['qty'] as num).toDouble();
    final dirStr = t['direction'] == 'buy' ? 'buy' : 'sell';
    final dir = t['direction'] == 'buy' ? 1.0 : -1.0;
    final mark = exitSidePrice(dirStr); // a buy is sold at bid, a sell bought back at ask
    if (mark == null) return null;
    return (mark - entry) * dir * qty;
  }

  double? movePct(Map<String, dynamic> t) {
    if (!priceOk || price == null) return null;
    final entry = (t['entry'] as num).toDouble();
    final dirStr = t['direction'] == 'buy' ? 'buy' : 'sell';
    final dir = t['direction'] == 'buy' ? 1.0 : -1.0;
    final mark = exitSidePrice(dirStr);
    if (mark == null) return null;
    return (mark - entry) / entry * 100 * dir;
  }

  double floatPnl() {
    double sum = 0;
    for (final t in positions.where((t) => t['status'] == 'open')) {
      sum += livePnl(t) ?? 0;
    }
    return sum;
  }

  Future<String?> openPaper(String dir, double qty, double? tp, double? sl) async {
    if (!priceFresh) return 'No fresh live price - cannot open right now.';
    final px = entrySidePrice(dir); // buy at ask, sell at bid
    if (px == null) return 'No fresh live price - cannot open right now.';
    try {
      await rpc('paper_open',
          {'p': pin, 'd': dir, 'price': px, 'q': qty, 'target': tp, 'stop': sl});
      await paperRefresh();
      return null;
    } on RpcException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not open trade';
    }
  }

  Future<String?> closePaper(Map<String, dynamic> t, {String? reason}) async {
    final id = t['id'].toString();
    if (closing.contains(id)) return null;
    if (!priceFresh) return 'No fresh live price - try Refresh';
    final px = exitSidePrice(t['direction'] == 'buy' ? 'buy' : 'sell');
    if (px == null) return 'No fresh live price - try Refresh';
    closing.add(id);
    notifyListeners();
    try {
      final r = await rpc('paper_close',
          {'p': pin, 'tid': t['id'], 'price': px, 'why': reason ?? 'Manual close'});
      closing.remove(id);
      await paperRefresh();
      final pnl = (r is Map && r['pnl'] != null) ? (r['pnl'] as num).toDouble() : null;
      return pnl != null ? 'closed:${money(pnl, sign: true)}' : 'closed';
    } catch (e) {
      closing.remove(id);
      notifyListeners();
      return e is RpcException ? e.message : 'Could not close';
    }
  }

  void checkTpsl() {
    if (!priceFresh || !unlocked) return;
    for (final t in positions.where((t) => t['status'] == 'open')) {
      final tp = effectiveLimit(t, 'tp');
      final sl = effectiveLimit(t, 'sl');
      final buy = t['direction'] == 'buy';
      final mark = exitSidePrice(buy ? 'buy' : 'sell');
      if (mark == null) continue;
      if (tp != null && ((buy && mark >= tp) || (!buy && mark <= tp))) {
        closePaper(t, reason: 'TP hit');
      } else if (sl != null && ((buy && mark <= sl) || (!buy && mark >= sl))) {
        closePaper(t, reason: 'SL hit');
      }
    }
  }

  Future<String?> saveTrade(Map<String, dynamic> t) async {
    try {
      await rpc('j_save', {'p': pin, 't': t});
      await refreshTrades();
      return null;
    } on RpcException catch (e) {
      return e.badPin ? 'PIN changed. Lock and re-enter.' : 'Could not save: ${e.message}';
    } catch (_) {
      return 'Could not save';
    }
  }

  Future<String?> deleteTrade(Map<String, dynamic> t) async {
    try {
      await rpc('j_delete', {'p': pin, 'tid': t['id']});
      await refreshTrades();
      return null;
    } catch (_) {
      return 'Could not delete';
    }
  }

  /// Edit the CURRENT paper balance (Oro request). Uses the additive
  /// paper_set_balance RPC; the backend guards by PIN and range.
  Future<String?> setBalance(double a) async {
    try {
      await rpc('paper_set_balance', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not update';
    }
  }

  Future<String?> setStarting(double a) async {
    try {
      await rpc('paper_balance', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not update';
    }
  }

  Future<String?> resetPaper(double a) async {
    try {
      await rpc('paper_reset', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not reset';
    }
  }

  List<({double pnl, DateTime at})> allClosed() {
    final out = <({double pnl, DateTime at})>[];
    for (final t in trades) {
      if (t['pnl'] != null) {
        out.add((
          pnl: (t['pnl'] as num).toDouble(),
          at: DateTime.tryParse(t['traded_at']?.toString() ?? '') ?? DateTime.now()
        ));
      }
    }
    for (final t in positions) {
      if (t['status'] == 'closed' && t['pnl'] != null) {
        out.add((
          pnl: (t['pnl'] as num).toDouble(),
          at: DateTime.tryParse(t['closed_at']?.toString() ?? '') ?? DateTime.now()
        ));
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }
}

ThemeData buildAppTheme() => ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: cBg,
      colorScheme: const ColorScheme.dark(
          surface: cCard, primary: cGreen, error: cRed, onSurface: Colors.white),
      appBarTheme: const AppBarTheme(backgroundColor: cBg, elevation: 0),
      cardColor: cCard,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cBg,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: cBorder)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: cBorder)),
      ),
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Local notifications + background TP/SL / alert checks (Oro request).
  // Android WorkManager minimum cadence is ~15 min; failures degrade silently.
  try {
    await initNotifications();
  } catch (_) {}
  runApp(const GoldApp());
}

class GoldApp extends StatelessWidget {
  const GoldApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oro',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  final app = AppState();
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && app.unlocked) {
      app.fetchPrice();
      app.paperRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        if (!app.unlocked) return LockScreen(app: app);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Oro',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            actions: [
              TextButton(
                  onPressed: app.lock,
                  child: const Text('Lock', style: TextStyle(color: cDim)))
            ],
          ),
          body: IndexedStack(
            index: tab,
            children: [
              TradeTab(app: app),
              PositionsTab(app: app),
              AddTab(app: app),
              StatsTab(app: app),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            backgroundColor: cCard,
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
              if (i == 0 || i == 1 || i == 3) app.paperRefresh();
              if (i == 2) app.refreshTrades();
            },
            destinations: [
              const NavigationDestination(icon: Icon(Icons.show_chart), label: 'Trade'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible:
                      app.positions.where((t) => t['status'] == 'open').isNotEmpty,
                  label: Text(
                      '${app.positions.where((t) => t['status'] == 'open').length}'),
                  child: const Icon(Icons.work_outline),
                ),
                label: 'Positions',
              ),
              const NavigationDestination(icon: Icon(Icons.add), label: 'Add'),
              const NavigationDestination(
                  icon: Icon(Icons.bar_chart), label: 'Stats'),
            ],
          ),
        );
      },
    );
  }
}

class LockScreen extends StatefulWidget {
  final AppState app;
  const LockScreen({super.key, required this.app});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Oro',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Enter your PIN', style: TextStyle(color: cDim)),
              const SizedBox(height: 20),
              TextField(
                controller: ctrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                onSubmitted: (_) => app.unlock(ctrl.text.trim()),
                decoration: const InputDecoration(hintText: 'PIN'),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: cGreen,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: app.unlocking ? null : () => app.unlock(ctrl.text.trim()),
                  child: Text(app.unlocking ? 'Opening...' : 'Open'),
                ),
              ),
              if (app.lockError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(app.lockError, style: const TextStyle(color: cRed)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget card(Widget child, {EdgeInsets? padding}) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cBorder),
      ),
      child: child,
    );

class TradeTab extends StatefulWidget {
  final AppState app;

  /// Optional test hook: override the candle source (stage b chart).
  /// When null the panel is driven by the configured Twelve Data key.
  final CandleLoader? candleLoaderOverride;
  const TradeTab({super.key, required this.app, this.candleLoaderOverride});
  @override
  State<TradeTab> createState() => _TradeTabState();
}

class _TradeTabState extends State<TradeTab> {
  String dir = 'buy';
  final qtyCtrl = TextEditingController(text: '1');
  final tpCtrl = TextEditingController();
  final slCtrl = TextEditingController();
  final alertCtrl = TextEditingController();
  bool alertAbove = true;
  bool opening = false;
  String err = '';

  // Stage (b): real candle service. Null when no API key is configured;
  // the chart panel then says so instead of drawing demo bars.
  final TwelveDataCandleService? _candles = MarketDataConfig.apiKey.isEmpty
      ? null
      : TwelveDataCandleService(apiKey: MarketDataConfig.apiKey);

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    // Keep the stage (d) risk row live as the user types.
    qtyCtrl.addListener(_refresh);
    slCtrl.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    qtyCtrl.dispose();
    slCtrl.dispose();
    tpCtrl.dispose();
    super.dispose();
  }

  double? parseNum(String s) {
    if (s.trim().isEmpty) return null;
    return double.tryParse(s.trim());
  }

  String agoText() {
    if (!app.priceOk) return 'price unavailable';
    final ago =
        ((DateTime.now().millisecondsSinceEpoch - app.priceAt) / 1000).round();
    return ago < 5 ? 'updated just now' : 'updated ${ago}s ago';
  }

  @override
  Widget build(BuildContext context) {
    final fresh = app.priceFresh;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        card(Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Gold (XAU/USD) live',
                      style: TextStyle(color: cDim, fontSize: 12)),
                  Text(app.priceOk ? '\$${fmt(app.price)}' : '--',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: fresh ? Colors.white : cDim)),
                  Text(agoText(), style: const TextStyle(color: cDim, fontSize: 11)),
                  if (app.bid != null && app.ask != null && app.spread != null && app.spread! > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Bid ${fmt(app.bid)}  Ask ${fmt(app.ask)}  Spread ${app.spread!.toStringAsFixed(2)}',
                        style: const TextStyle(color: cDim, fontSize: 11, fontFamily: 'Roboto'),
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
                onPressed: app.fetchPrice,
                child: const Text('Refresh', style: TextStyle(color: cDim))),
          ],
        )),
        const SizedBox(height: 10),
        CandleChartPanel(
          loader: widget.candleLoaderOverride ??
              (_candles == null
                  ? null
                  : (iv) => _candles.fetchCandles(Instrument.xauUsd,
                      interval: iv, limit: 120)),
          livePrice: app.price,
        ),
        const SizedBox(height: 10),
        card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Price alerts',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: alertCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Alert price', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => alertAbove = !alertAbove),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: cBorder),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(alertAbove ? 'Above' : 'Below',
                      style: const TextStyle(color: cDim, fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final v = double.tryParse(alertCtrl.text.trim());
                  if (v != null && v > 0) {
                    app.addAlert(v, alertAbove);
                    alertCtrl.clear();
                  }
                },
                child: const Text('Add'),
              ),
            ]),
            if (app.alerts.isNotEmpty) const SizedBox(height: 8),
            ...app.alerts.map((a) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Icon(
                        a.triggered
                            ? Icons.notifications_active
                            : Icons.notifications_none,
                        size: 14,
                        color: a.triggered ? const Color(0xFFF5C242) : cDim),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${a.above ? 'Above' : 'Below'} ${fmt(a.level)}${a.triggered ? '  -  triggered' : ''}',
                        style: TextStyle(
                            color: a.triggered ? const Color(0xFFF5C242) : cDim,
                            fontSize: 12),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => app.removeAlert(a.id),
                      child: const Icon(Icons.delete_outline,
                          size: 16, color: cDim),
                    ),
                  ]),
                )),
          ],
        )),
        const SizedBox(height: 10),
        if (app.alertBanner != null)
          card(Row(children: [
            const Icon(Icons.notifications_active,
                color: Color(0xFFF5C242), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Price alert: XAU/USD ${app.alertBanner!.above ? 'reached' : 'dropped to'} ${fmt(app.alertBanner!.level)}',
                style: const TextStyle(
                    color: Color(0xFFF5C242),
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
            GestureDetector(
              onTap: app.dismissAlertBanner,
              child: const Icon(Icons.close, color: cDim, size: 18),
            ),
          ])),
        if (!fresh)
          card(Row(children: [
            const Icon(Icons.warning_amber, color: Colors.amber, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                app.priceOk
                    ? 'Price looks stale - check internet before opening or closing.'
                    : 'Cannot reach the price feed right now. You can still view, but open/close is paused.',
                style: const TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ),
          ])),
        card(Column(children: [
          Row(children: [
            Expanded(child: _balRow('Paper balance', money(app.balance), cls(app.balance - app.starting))),
            TextButton(
              onPressed: () => _editBalance(context),
              child: const Text('Edit', style: TextStyle(color: cDim, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _balRow('Starting', money(app.starting), cDim)),
            TextButton(
              onPressed: () => _editStarting(context),
              child: const Text('Edit', style: TextStyle(color: cDim, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          _balRow('Open PnL', app.priceOk ? money(app.floatPnl(), sign: true) : '-',
              cls(app.floatPnl())),
        ])),
        const Text('New order',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: _segBtn('Buy', cGreen, dir == 'buy', () => setState(() => dir = 'buy')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _segBtn('Sell', cRed, dir == 'sell', () => setState(() => dir = 'sell')),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: qtyCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Size (oz of gold)'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: tpCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Take profit (optional)'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: slCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Stop loss (optional)'),
                ),
              ),
            ]),
            _riskRow(),
            if (err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(err, style: const TextStyle(color: cRed, fontSize: 12)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: dir == 'buy' ? cGreen : cRed,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: (!fresh || opening)
                  ? null
                  : () async {
                      final q = parseNum(qtyCtrl.text);
                      if (q == null || q <= 0) {
                        setState(() => err = 'Enter a size in oz (like 0.5 or 1).');
                        return;
                      }
                      setState(() {
                        opening = true;
                        err = '';
                      });
                      final r = await app.openPaper(
                          dir, q, parseNum(tpCtrl.text), parseNum(slCtrl.text));
                      if (!mounted) return;
                      if (r != null) {
                        setState(() => err = r);
                      } else {
                        tpCtrl.clear();
                        slCtrl.clear();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(
                                '${dir.toUpperCase()} opened at ${fmt(app.price)}'),
                            duration: const Duration(seconds: 2)));
                      }
                      setState(() => opening = false);
                    },
              child: Text(opening
                  ? 'Opening...'
                  : '${dir == 'buy' ? 'Buy' : 'Sell'} at live price'),
            ),
            const SizedBox(height: 8),
            const Text(
              'TP/SL auto-close works only while the app is open.',
              style: TextStyle(color: cDim, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        )),
      ],
    );
  }

  Future<void> _editBalance(BuildContext context) async {
    final ctrl = TextEditingController(text: fmt(app.balance));
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('Set current balance (USD)'),
        content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      final a = double.tryParse(ctrl.text.trim());
      if (a != null && a >= 0) {
        final e = await app.setBalance(a);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e ?? 'Balance updated'),
              duration: const Duration(seconds: 2)));
        }
      }
    }
  }

  /// Stage (d): live risk readout for the order being composed.
  /// Shows $ at risk from the stop distance, and a one-tap size that
  /// risks 1% of the paper balance. Entry is the real side price.
  Widget _riskRow() {
    final entry = app.entrySidePrice(dir);
    final qty = parseNum(qtyCtrl.text);
    final sl = parseNum(slCtrl.text);
    if (entry == null) return const SizedBox.shrink();
    final risk = (qty != null && sl != null)
        ? (entry - sl).abs() * qty
        : null;
    final suggested = riskQty(app.balance * 0.01, entry, sl);
    final pct = risk != null && app.balance > 0 ? risk / app.balance * 100 : null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        Expanded(
          child: Text(
            risk == null
                ? (sl == null
                    ? 'Add a stop loss to size by risk'
                    : 'Enter size and stop to see risk')
                : 'Risk ${money(risk, sign: false)} (${pct!.toStringAsFixed(1)}% of balance)',
            style: TextStyle(
                color: risk == null
                    ? cDim
                    : (pct! > 2 ? cRed : Colors.amber),
                fontSize: 12),
          ),
        ),
        if (suggested != null)
          GestureDetector(
            onTap: () => setState(
                () => qtyCtrl.text = suggested.toStringAsFixed(2)),
            child: Text('1% size: ${suggested.toStringAsFixed(2)} oz',
                style: const TextStyle(
                    color: Color(0xFFF5C242),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }

  Widget _balRow(String label, String value, Color color) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: cDim, fontSize: 13)),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: color)),
        ],
      );

  Widget _segBtn(String label, Color color, bool on, VoidCallback tap) => GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.2) : cBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? color : cBorder, width: on ? 1.5 : 1),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: on ? color : cDim, fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      );

  Future<void> _editStarting(BuildContext context) async {
    final ctrl = TextEditingController(text: app.starting.toStringAsFixed(0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('New starting balance (\$)'),
        content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      final a = double.tryParse(ctrl.text.trim());
      if (a != null && a >= 0) {
        final e = await app.setStarting(a);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e ?? 'Starting balance updated'),
            duration: const Duration(seconds: 2)));
      }
    }
  }
}

class PositionsTab extends StatefulWidget {
  final AppState app;
  const PositionsTab({super.key, required this.app});
  @override
  State<PositionsTab> createState() => _PositionsTabState();
}

class _PositionsTabState extends State<PositionsTab> {
  bool showHistory = false;

  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final open = app.positions.where((t) => t['status'] == 'open').toList();
    final hist = app.positions.where((t) => t['status'] == 'closed').toList()
      ..sort((a, b) => (b['closed_at'] ?? '').toString().compareTo((a['closed_at'] ?? '').toString()));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(children: [
            Expanded(
                child: _tabBtn('Open Positions (${open.length})', !showHistory,
                    () => setState(() => showHistory = false))),
            const SizedBox(width: 8),
            Expanded(
                child: _tabBtn(
                    'History', showHistory, () => setState(() => showHistory = true))),
          ]),
        ),
        Expanded(
          child: showHistory ? _historyList(hist) : _openList(open),
        ),
      ],
    );
  }

  Widget _tabBtn(String label, bool on, VoidCallback tap) => GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: on ? cCard : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? cBorder : Colors.transparent),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: on ? Colors.white : cDim,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      );

  Widget _openList(List<Map<String, dynamic>> open) {
    if (open.isEmpty) {
      return const Center(
          child: Text('No open positions', style: TextStyle(color: cDim)));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      itemCount: open.length + 1,
      itemBuilder: (ctx, i) {
        if (i == open.length) {
          return const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'TP/SL switches are saved on this device and auto-close runs only while the app is open.',
              style: TextStyle(color: cDim, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          );
        }
        return _positionCard(open[i]);
      },
    );
  }

  Widget _positionCard(Map<String, dynamic> t) {
    final id = t['id'].toString();
    final buy = t['direction'] == 'buy';
    final qty = (t['qty'] as num).toDouble();
    final live = app.livePnl(t);
    final isExpanded = app.expanded.contains(id);
    final tp = app.effectiveLimit(t, 'tp');
    final sl = app.effectiveLimit(t, 'sl');
    final isClosing = app.closing.contains(id);
    return card(
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() {
            isExpanded ? app.expanded.remove(id) : app.expanded.add(id);
          }),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('GOLD',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(buy ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 13, color: buy ? cGreen : cRed),
                  const SizedBox(width: 3),
                  Text('${fmt(qty)} oz  ${buy ? 'BUY' : 'SELL'}',
                      style: TextStyle(color: buy ? cGreen : cRed, fontSize: 12)),
                ]),
              ]),
            ),
            Text(money(live, sign: true),
                style: TextStyle(
                    color: cls(live), fontWeight: FontWeight.w700, fontSize: 16)),
            Icon(isExpanded ? Icons.expand_less : Icons.expand_more, color: cDim),
          ]),
        ),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: cRed,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12)),
          onPressed: (!app.priceFresh || isClosing) ? null : () => _confirmClose(t),
          child: Text(isClosing ? 'Closing...' : 'Close Trade: ${money(live, sign: true)}'),
        ),
        if (isExpanded) ...[
          const Divider(color: cBorder, height: 24),
          _row('Order ID', id),
          _row('Instrument', 'GOLD'),
          _row('Amount', '${fmt(qty)} Troy Ounce${qty == 1 ? '' : 's'}'),
          _row('Direction', buy ? 'BUY' : 'SELL'),
          _row('Open Price', fmt((t['entry'] as num).toDouble())),
          _row('Current Price', app.priceOk ? fmt(app.price) : 'Unavailable'),
          _row('PnL', money(live, sign: true), color: cls(live)),
          _row('Price Move (%)', () {
            final m = app.movePct(t);
            return m == null ? '-' : '${m > 0 ? '+' : ''}${m.toStringAsFixed(3)}%';
          }()),
          _row('Time Opened', _fmtTime(t['opened_at']?.toString())),
          _row('Take Profit / Stop Loss',
              '${tp == null ? '-' : fmt(tp)} / ${sl == null ? '-' : fmt(sl)}'),
          const SizedBox(height: 8),
          _limitSwitch(t, 'tp', 'Take Profit', tp),
          _limitSwitch(t, 'sl', 'Stop Loss', sl),
        ],
      ]),
      padding: const EdgeInsets.all(14),
    );
  }

  Widget _limitSwitch(Map<String, dynamic> t, String key, String label, double? v) {
    final on = v != null;
    return InkWell(
      onTap: () async {
        if (on) {
          setState(() => app.setLimit(t['id'].toString(), key, null));
        } else {
          await _askLimit(t, key, label);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 14)),
              Text(on ? fmt(v) : 'Off',
                  style: const TextStyle(color: cDim, fontSize: 12)),
            ]),
          ),
          Switch(
            value: on,
            activeTrackColor: cGreen,
            onChanged: (nv) async {
              if (!nv) {
                setState(() => app.setLimit(t['id'].toString(), key, null));
              } else {
                await _askLimit(t, key, label);
              }
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _askLimit(Map<String, dynamic> t, String key, String label) async {
    final buy = t['direction'] == 'buy';
    final existing = t[key];
    final ctrl = TextEditingController(text: existing == null ? '' : fmt((existing as num).toDouble()));
    String? error;
    final val = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: cCard,
          title: Text('$label price (\$ per troy ounce)',
              style: const TextStyle(fontSize: 16)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(hintText: 'e.g. 4200')),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: cRed, fontSize: 12)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(ctrl.text.trim());
                if (v == null || v <= 0) {
                  setD(() => error = 'Enter a positive price');
                  return;
                }
                final above = key == 'tp' ? buy : !buy;
                if (app.priceFresh &&
                    (above ? v <= app.price! : v >= app.price!)) {
                  setD(() => error =
                      'Choose a level ${above ? 'above' : 'below'} the current price');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    if (val != null) setState(() => app.setLimit(t['id'].toString(), key, val));
  }

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: cDim, fontSize: 13)),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color ?? Colors.white)),
            ),
          ],
        ),
      );

  String _fmtTime(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '-';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.day)}/${p(d.month)}/${p(d.year % 100)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  Future<void> _confirmClose(Map<String, dynamic> t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: Text('Close this ${t['direction'].toString().toUpperCase()} at the live price?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cRed),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Close')),
        ],
      ),
    );
    if (ok == true) {
      final r = await app.closePaper(t);
      if (!mounted) return;
      if (r != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.startsWith('closed')
                ? 'Closed at ${fmt(app.price)}${r.contains(':') ? ' · ${r.split(':')[1]}' : ''}'
                : r),
            duration: const Duration(seconds: 2)));
      }
    }
  }

  /// Stage (e): journal note editor for a closed paper trade.
  Future<void> _editNote(
      BuildContext context, Map<String, dynamic> t, String current) async {
    final ctrl = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('Journal note'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
              hintText: 'Why did you take this trade? What happened?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      app.setTradeNote(t['id'].toString(), ctrl.text);
    }
  }

  Widget _historyList(List<Map<String, dynamic>> hist) {
    if (hist.isEmpty) {
      return const Center(
          child: Text('No closed trades yet', style: TextStyle(color: cDim)));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      itemCount: hist.length,
      itemBuilder: (ctx, i) {
        final t = hist[i];
        final buy = t['direction'] == 'buy';
        final pnl = t['pnl'] == null ? null : (t['pnl'] as num).toDouble();
        final d = DateTime.tryParse(t['closed_at']?.toString() ?? '')?.toLocal();
        return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              _pill(buy ? 'BUY' : 'SELL', buy),
              const SizedBox(width: 8),
              Text('${fmt((t['qty'] as num).toDouble())} oz',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            Text(money(pnl, sign: true),
                style: TextStyle(color: cls(pnl), fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(
            'Entry ${fmt((t['entry'] as num).toDouble())} → Exit ${t['exit'] == null ? '-' : fmt((t['exit'] as num).toDouble())}'
            '${t['reason'] != null && t['reason'].toString().isNotEmpty ? ' · ${t['reason']}' : ''}\n'
            '${d == null ? '' : '${d.day} ${_month(d.month)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'}',
            style: const TextStyle(color: cDim, fontSize: 12, height: 1.4),
          ),
          Builder(builder: (ctx2) {
            final note = app.tradeNotes[t['id'].toString()] ?? '';
            return GestureDetector(
              onTap: () => _editNote(ctx2, t, note),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  const Icon(Icons.edit_note, size: 14, color: cDim),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      note.isEmpty ? 'Add a journal note' : note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: note.isEmpty ? cDim : Colors.white70,
                          fontSize: 11,
                          fontStyle: note.isEmpty
                              ? FontStyle.italic
                              : FontStyle.normal),
                    ),
                  ),
                ]),
              ),
            );
          }),
        ]));
      },
    );
  }

  String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][m - 1];
}

Widget _pill(String label, bool buy) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (buy ? cGreen : cRed).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              color: buy ? cGreen : cRed,
              fontSize: 11,
              fontWeight: FontWeight.bold)),
    );

class AddTab extends StatefulWidget {
  final AppState app;
  const AddTab({super.key, required this.app});
  @override
  State<AddTab> createState() => _AddTabState();
}

class _AddTabState extends State<AddTab> {
  String dir = 'buy';
  String editingId = '';
  final instrumentCtrl = TextEditingController(text: 'XAU/USD');
  final entryCtrl = TextEditingController();
  final exitCtrl = TextEditingController();
  final pnlCtrl = TextEditingController();
  final tpCtrl = TextEditingController();
  final slCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  DateTime when = DateTime.now();
  bool pnlManual = false;
  bool saving = false;
  String err = '';

  AppState get app => widget.app;

  void autoPnl() {
    if (pnlManual) return;
    final en = double.tryParse(entryCtrl.text.trim());
    final ex = double.tryParse(exitCtrl.text.trim());
    if (en != null && ex != null) {
      final v = (ex - en) * (dir == 'buy' ? 1 : -1);
      pnlCtrl.text = ((v * 100).round() / 100).toString();
    } else {
      pnlCtrl.text = '';
    }
  }

  void resetForm() {
    setState(() {
      editingId = '';
      dir = 'buy';
      instrumentCtrl.text = 'XAU/USD';
      entryCtrl.clear();
      exitCtrl.clear();
      pnlCtrl.clear();
      tpCtrl.clear();
      slCtrl.clear();
      noteCtrl.clear();
      when = DateTime.now();
      pnlManual = false;
      err = '';
    });
  }

  void editTrade(Map<String, dynamic> t) {
    setState(() {
      editingId = t['id'].toString();
      dir = t['direction']?.toString() ?? 'buy';
      instrumentCtrl.text = t['instrument']?.toString() ?? 'XAU/USD';
      entryCtrl.text = t['entry']?.toString() ?? '';
      exitCtrl.text = t['exit']?.toString() ?? '';
      pnlCtrl.text = t['pnl']?.toString() ?? '';
      pnlManual = t['pnl'] != null;
      tpCtrl.text = t['tp']?.toString() ?? '';
      slCtrl.text = t['sl']?.toString() ?? '';
      noteCtrl.text = t['note']?.toString() ?? '';
      when = DateTime.tryParse(t['traded_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now();
      err = '';
    });
  }

  double? pn(String s) => s.trim().isEmpty ? null : double.tryParse(s.trim());

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Text(editingId.isEmpty ? 'Add XM trade' : 'Edit trade',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: _seg('Buy', cGreen, dir == 'buy',
                    () => setState(() { dir = 'buy'; autoPnl(); }))),
            const SizedBox(width: 8),
            Expanded(
                child: _seg('Sell', cRed, dir == 'sell',
                    () => setState(() { dir = 'sell'; autoPnl(); }))),
          ]),
          const SizedBox(height: 10),
          TextField(
              controller: instrumentCtrl,
              decoration: const InputDecoration(labelText: 'Instrument')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: entryCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => autoPnl(),
                    decoration: const InputDecoration(labelText: 'Entry'))),
            const SizedBox(width: 10),
            Expanded(
                child: TextField(
                    controller: exitCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => autoPnl(),
                    decoration: const InputDecoration(labelText: 'Exit (optional)'))),
          ]),
          const SizedBox(height: 10),
          TextField(
              controller: pnlCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              onChanged: (v) => setState(() => pnlManual = v.isNotEmpty),
              decoration: const InputDecoration(labelText: 'PnL \$ (auto)')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: tpCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'TP (optional)'))),
            const SizedBox(width: 10),
            Expanded(
                child: TextField(
                    controller: slCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'SL (optional)'))),
          ]),
          const SizedBox(height: 10),
          TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: 'Note (optional)')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: cBorder),
                padding: const EdgeInsets.symmetric(vertical: 12)),
            icon: const Icon(Icons.schedule, color: cDim, size: 18),
            label: Text(
              '${when.day}/${when.month}/${when.year} ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(color: Colors.white),
            ),
            onPressed: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: when,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 1)));
              if (d == null || !mounted) return;
              final tm = await showTimePicker(
                  context: context, initialTime: TimeOfDay.fromDateTime(when));
              if (tm == null) return;
              setState(() =>
                  when = DateTime(d.year, d.month, d.day, tm.hour, tm.minute));
            },
          ),
          if (err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(err, style: const TextStyle(color: cRed, fontSize: 12)),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: cGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13)),
                onPressed: saving ? null : _save,
                child: Text(saving
                    ? 'Saving...'
                    : (editingId.isEmpty ? 'Save trade' : 'Update trade')),
              ),
            ),
            if (editingId.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: cBorder),
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                  onPressed: resetForm,
                  child: const Text('Cancel', style: TextStyle(color: cDim))),
            ],
          ]),
        ])),
        const SizedBox(height: 6),
        const Text('Logged trades',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (app.trades.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
                child: Text('No trades logged yet', style: TextStyle(color: cDim))),
          )
        else
          ...app.trades.map((t) => _tradeTile(t)),
      ],
    );
  }

  Widget _seg(String label, Color color, bool on, VoidCallback tap) => GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.2) : cBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? color : cBorder, width: on ? 1.5 : 1),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(color: on ? color : cDim, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _tradeTile(Map<String, dynamic> t) {
    final buy = t['direction'] == 'buy';
    final pnl = t['pnl'] == null ? null : (t['pnl'] as num).toDouble();
    final d = DateTime.tryParse(t['traded_at']?.toString() ?? '')?.toLocal();
    return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          _pill(buy ? 'BUY' : 'SELL', buy),
          const SizedBox(width: 8),
          Text(t['instrument']?.toString() ?? 'XAU/USD',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        Text(pnl == null ? 'open' : money(pnl, sign: true),
            style: TextStyle(color: cls(pnl), fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 6),
      Text(
        'Entry ${t['entry'] ?? '-'}'
        '${t['exit'] != null ? ' → Exit ${t['exit']}' : ''}'
        '${t['tp'] != null ? ' · TP ${t['tp']}' : ''}'
        '${t['sl'] != null ? ' · SL ${t['sl']}' : ''}'
        '${d != null ? '\n${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}' : ''}',
        style: const TextStyle(color: cDim, fontSize: 12, height: 1.4),
      ),
      if (t['note'] != null && t['note'].toString().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t['note'].toString(),
              style: const TextStyle(fontSize: 12, color: cDim)),
        ),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(
            onPressed: () => editTrade(t),
            child: const Text('Edit', style: TextStyle(color: cDim, fontSize: 12))),
        TextButton(
            onPressed: () => _del(t),
            child: const Text('Delete', style: TextStyle(color: cRed, fontSize: 12))),
      ]),
    ]));
  }

  Future<void> _save() async {
    final en = pn(entryCtrl.text);
    if (en == null) {
      setState(() => err = 'Enter the entry price');
      return;
    }
    var pnl = pn(pnlCtrl.text);
    final ex = pn(exitCtrl.text);
    if (pnl == null && ex != null) {
      pnl = ((ex - en) * (dir == 'buy' ? 1 : -1) * 100).round() / 100;
    }
    final t = {
      'id': editingId,
      'instrument': instrumentCtrl.text.trim().isEmpty
          ? 'XAU/USD'
          : instrumentCtrl.text.trim(),
      'direction': dir,
      'entry': en,
      'exit': ex,
      'pnl': pnl,
      'tp': pn(tpCtrl.text),
      'sl': pn(slCtrl.text),
      'note': noteCtrl.text.trim(),
      'traded_at': when.toUtc().toIso8601String(),
    };
    setState(() {
      saving = true;
      err = '';
    });
    final r = await app.saveTrade(t);
    if (!mounted) return;
    if (r != null) {
      setState(() {
        err = r;
        saving = false;
      });
    } else {
      final wasEdit = editingId.isNotEmpty;
      resetForm();
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasEdit ? 'Trade updated' : 'Trade saved'),
          duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _del(Map<String, dynamic> t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('Delete this trade?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cRed),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      final r = await app.deleteTrade(t);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r ?? 'Deleted'), duration: const Duration(seconds: 2)));
      if (editingId == t['id'].toString()) resetForm();
    }
  }
}

class StatsTab extends StatelessWidget {
  final AppState app;
  const StatsTab({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final done = app.allClosed().map((t) => t.pnl).toList();
    final total = done.fold<double>(0, (a, b) => a + b);
    final wins = done.where((x) => x > 0).length;
    final pf = profitFactor(done);
    final avgWin = avgOf(done.where((x) => x > 0));
    final avgLoss = avgOf(done.where((x) => x < 0));
    final mdd = maxDrawdown(app.starting, done);
    final streak = currentStreak(done);
    final risk = openRisk(app.positions
        .where((t) => t['status'] == 'open')
        .map((t) => (
              entry: (t['entry'] as num).toDouble(),
              qty: (t['qty'] as num).toDouble(),
              stop: (app.effectiveLimit(t, 'sl'))?.toDouble(),
            )));
    final count = app.trades.length +
        app.positions.where((t) => t['status'] == 'closed').length;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        card(Column(children: [
          _stat('Paper balance', money(app.balance), cls(app.balance - app.starting)),
          _stat('Total PnL (closed)', done.isEmpty ? '-' : '\$${fmt(total, sign: true)}',
              done.isEmpty ? cDim : cls(total)),
          _stat('Win rate', done.isEmpty ? '-' : '${(wins / done.length * 100).round()}%',
              cDim),
          _stat('Trades', '$count', cDim),
          _stat('Best', done.isEmpty ? '-' : '\$${fmt(done.reduce(math.max), sign: true)}',
              done.isEmpty ? cDim : cls(done.reduce(math.max))),
          _stat('Worst', done.isEmpty ? '-' : '\$${fmt(done.reduce(math.min), sign: true)}',
              done.isEmpty ? cDim : cls(done.reduce(math.min))),
          _stat('Avg', done.isEmpty ? '-' : '\$${fmt(total / done.length, sign: true)}',
              done.isEmpty ? cDim : cls(total)),
          _stat('Profit factor', pf == null ? '-' : pf.toStringAsFixed(2), cDim),
          _stat('Avg win', avgWin == null ? '-' : '\$${fmt(avgWin, sign: true)}',
              avgWin == null ? cDim : cls(avgWin)),
          _stat('Avg loss', avgLoss == null ? '-' : '\$${fmt(avgLoss, sign: true)}',
              avgLoss == null ? cDim : cls(avgLoss)),
          _stat('Max drawdown', done.isEmpty ? '-' : '-\$${fmt(mdd)}',
              done.isEmpty ? cDim : (mdd > 0 ? cRed : cDim)),
          _stat(
              'Streak',
              streak == 0
                  ? '-'
                  : streak > 0
                      ? '$streak wins'
                      : '${-streak} losses',
              streak == 0
                  ? cDim
                  : streak > 0
                      ? cGreen
                      : cRed),
          _stat('Open risk', risk == 0 ? '-' : '-\$${fmt(risk)}',
              risk == 0 ? cDim : Colors.amber),
        ])),
        const Text('Equity curve',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        card(app.allClosed().isEmpty
            ? const Padding(
                padding: EdgeInsets.all(30),
                child: Center(
                    child: Text('Close a trade to see the chart',
                        style: TextStyle(color: cDim))),
              )
            : SizedBox(
                height: 200,
                child: CustomPaint(
                  painter: EquityPainter(app.allClosed().map((t) => t.pnl).toList()),
                  size: Size.infinite,
                ),
              )),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: cRed),
              padding: const EdgeInsets.symmetric(vertical: 12)),
          onPressed: () => _reset(context),
          child: const Text('Reset paper account', style: TextStyle(color: cRed)),
        ),
      ],
    );
  }

  Widget _stat(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: cDim, fontSize: 13)),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: color)),
        ]),
      );

  Future<void> _reset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('Reset the paper account?'),
        content: const Text('This deletes all paper trades and sets the balance back.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cRed),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final ctrl = TextEditingController(text: '10000');
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('Starting balance after reset (\$)'),
        content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok2 == true) {
      final a = double.tryParse(ctrl.text.trim());
      if (a != null && a >= 0) {
        final e = await app.resetPaper(a);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e ?? 'Paper account reset'),
              duration: const Duration(seconds: 2)));
        }
      }
    }
  }
}

class EquityPainter extends CustomPainter {
  final List<double> pnls;
  EquityPainter(this.pnls);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <double>[0];
    double cum = 0;
    for (final p in pnls) {
      cum += p;
      pts.add(cum);
    }
    final mn = math.min(0.0, pts.reduce(math.min));
    final mx = math.max(0.0, pts.reduce(math.max));
    final rg = (mx - mn) == 0 ? 1.0 : (mx - mn);
    const pl = 52.0, pr = 14.0, pt = 16.0, pb = 26.0;
    double x(int i) =>
        pl + (pts.length < 2 ? 0 : i * (size.width - pl - pr) / (pts.length - 1));
    double y(double v) => pt + (mx - v) * (size.height - pt - pb) / rg;

    final grid = Paint()
      ..color = cBorder
      ..strokeWidth = 1;
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (int k = 0; k <= 4; k++) {
      final v = mn + rg * k / 4;
      final yy = y(v);
      canvas.drawLine(Offset(pl, yy), Offset(size.width - pr, yy), grid);
      label.text = TextSpan(
          text: fmt(v),
          style: const TextStyle(color: cDim, fontSize: 11, fontFamily: 'Roboto'));
      label.layout();
      label.paint(canvas, Offset(4, yy - 6));
    }
    canvas.drawLine(Offset(pl, y(0)), Offset(size.width - pr, y(0)),
        Paint()..color = const Color(0xFF3A4150));

    final up = pts.last >= 0;
    final line = Paint()
      ..color = up ? cGreen : cRed
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (int i = 0; i < pts.length; i++) {
      if (i == 0) {
        path.moveTo(x(i), y(pts[i]));
      } else {
        path.lineTo(x(i), y(pts[i]));
      }
    }
    canvas.drawPath(path, line);
    final dot = Paint()..color = up ? cGreen : cRed;
    for (int i = 1; i < pts.length; i++) {
      canvas.drawCircle(Offset(x(i), y(pts[i])), 3.5, dot);
    }
    label.text = const TextSpan(
        text: 'trade #',
        style: TextStyle(color: cDim, fontSize: 11, fontFamily: 'Roboto'));
    label.layout();
    label.paint(canvas, Offset(size.width / 2 - 16, size.height - 14));
  }

  @override
  bool shouldRepaint(EquityPainter old) => true;
}
