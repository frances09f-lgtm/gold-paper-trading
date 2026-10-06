/// Auto-trade engine: cadence + hard safety rails around the AI brain.
/// Background-safe (http + shared_preferences only). The brain proposes;
/// these rails dispose - the model cannot override any limit here.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_brain.dart';
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';
import 'notifications.dart';
import 'sessions.dart';

class AiLogEntry {
  final DateTime at;
  final String kind; // 'decision' | 'trade' | 'pause' | 'error'
  final String text;
  const AiLogEntry(this.at, this.kind, this.text);

  Map<String, dynamic> toJson() =>
      {'at': at.toIso8601String(), 'kind': kind, 'text': text};
  static AiLogEntry fromJson(Map<String, dynamic> j) => AiLogEntry(
      DateTime.tryParse(j['at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      j['kind'] as String? ?? 'decision',
      j['text'] as String? ?? '');
}

/// On-device AI log (like NotificationLog), capped at 100.
class AiLog {
  static const _key = 'tj_ai_log';

  static Future<void> add(String kind, String text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = read(prefs);
      entries.insert(0, AiLogEntry(DateTime.now(), kind, text));
      if (entries.length > 100) entries.removeRange(100, entries.length);
      await prefs.setString(
          _key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  static List<AiLogEntry> read(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => AiLogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class AutoTradeStatus {
  final bool enabled;
  final double sizePct;
  final int tradesToday;
  final int consecutiveLosses;
  final String? pausedReason;
  final DateTime? lastRunAt;
  final bool keyConfigured;

  const AutoTradeStatus({
    required this.enabled,
    required this.sizePct,
    required this.tradesToday,
    required this.consecutiveLosses,
    required this.pausedReason,
    required this.lastRunAt,
    required this.keyConfigured,
  });
}

class AutoTrade {
  static const _enabledKey = 'tj_ai_enabled';
  static const _sizeKey = 'tj_ai_size_pct';
  static const _countDateKey = 'tj_ai_count_date';
  static const _countKey = 'tj_ai_count';
  static const _lossesKey = 'tj_ai_losses';
  static const _cooldownKey = 'tj_ai_cooldown';
  static const _pauseKey = 'tj_ai_pause';
  static const _lastRunKey = 'tj_ai_last_run';
  static const _dayBalKey = 'tj_ai_day_balance';
  static const _openIdKey = 'tj_ai_open_id';
  static const _openEquityKey = 'tj_ai_open_equity';

  // Hard rails (see approved design).
  static const maxTradesPerDay = 5;
  static const maxConsecutiveLosses = 2;
  static const dailyDrawdownPct = 0.02;
  static const cooldownAfterClose = Duration(minutes: 15);
  static const cadence = Duration(minutes: 15);

  static Future<AutoTradeStatus> status(SharedPreferences prefs) async {
    _rollDay(prefs);
    return AutoTradeStatus(
      enabled: prefs.getBool(_enabledKey) ?? false,
      sizePct: prefs.getDouble(_sizeKey) ?? 10,
      tradesToday: prefs.getInt(_countKey) ?? 0,
      consecutiveLosses: prefs.getInt(_lossesKey) ?? 0,
      pausedReason: prefs.getString(_pauseKey),
      lastRunAt: DateTime.tryParse(prefs.getString(_lastRunKey) ?? ''),
      keyConfigured: AiConfig.groqApiKey.isNotEmpty,
    );
  }

  static Future<void> setEnabled(SharedPreferences prefs, bool on) async {
    await prefs.setBool(_enabledKey, on);
    if (on) {
      await prefs.remove(_pauseKey);
      await AiLog.add('decision', 'Auto-trade switched ON');
    } else {
      await AiLog.add('decision', 'Auto-trade switched OFF');
    }
  }

  static Future<void> setSizePct(SharedPreferences prefs, double pct) async {
    await prefs.setDouble(_sizeKey, pct.clamp(1, 25));
  }

  static Future<void> resume(SharedPreferences prefs) async {
    await prefs.remove(_pauseKey);
    await prefs.setInt(_lossesKey, 0);
    await AiLog.add('decision', 'Auto-trade resumed by user');
  }

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static void _rollDay(SharedPreferences prefs) {
    if (prefs.getString(_countDateKey) != _today()) {
      prefs.setString(_countDateKey, _today());
      prefs.setInt(_countKey, 0);
      prefs.remove(_dayBalKey);
    }
  }

  // ---------- tick ----------

  /// One decision cycle. [manual] = user tapped "Think now" (skips cadence).
  /// Returns a human summary of what happened.
  static Future<String> think(SharedPreferences prefs,
      {bool manual = false, GroqBrain? brain}) async {
    final st = await status(prefs);
    if (!st.enabled) return 'Auto-trade is off';
    if (!st.keyConfigured) {
      await _pause(prefs, 'AI key missing in this build');
      return 'AI key missing - auto-trade paused';
    }
    if (st.pausedReason != null && !manual) {
      return 'Paused: ${st.pausedReason}';
    }
    final now = DateTime.now();
    final lastRun = st.lastRunAt;
    if (!manual && lastRun != null && now.difference(lastRun) < cadence) {
      return 'Not due yet';
    }
    final cooldownRaw = prefs.getString(_cooldownKey);
    if (!manual && cooldownRaw != null) {
      final until = DateTime.tryParse(cooldownRaw);
      if (until != null && now.isBefore(until)) return 'Cooling down after a close';
    }
    await prefs.setString(_lastRunKey, now.toIso8601String());

    final pin = prefs.getString('tj_pin') ?? '';
    if (pin.isEmpty) return 'App not unlocked on this device';

    // --- gather real data ---
    final quote = await _fetchQuote();
    if (quote == null) {
      final closed = marketClosedMessage();
      if (closed != null) {
        await AiLog.add('decision', 'Skipped: $closed');
        return 'Skipped: $closed';
      }
      await AiLog.add('error', 'No live quote - skipped this cycle');
      return 'No live quote - skipped';
    }
    List<Candle> candles;
    try {
      candles = await TwelveDataCandleService(apiKey: MarketDataConfig.apiKey)
          .fetchCandles(Instrument.xauUsd, interval: '15min', limit: 60);
    } catch (e) {
      await AiLog.add('error', 'No candle data - skipped this cycle ($e)');
      return 'No candle data - skipped';
    }
    final (state, stateErr) = await _paperState(pin);
    if (state == null) {
      if (stateErr != null && stateErr.startsWith('PIN rejected')) {
        await prefs.remove('tj_pin');
      }
      await AiLog.add('error', 'Paper account read failed: $stateErr');
      return 'Could not read paper account - $stateErr';
    }
    final balance = (state['balance'] as num).toDouble();
    final positions =
        List<Map<String, dynamic>>.from(state['positions'] as List? ?? []);
    // paper_state returns the FULL trade history, not just open trades.
    // Everything below must reason over the open ones only, or any closed
    // trade in history reads as "a position is already open" forever.
    final openPositions =
        positions.where((p) => p['status'] == 'open').toList();

    // Day-start balance for the drawdown rail.
    if (prefs.getString(_dayBalKey) == null) {
      await prefs.setString(_dayBalKey, balance.toString());
    }
    final dayBal =
        double.tryParse(prefs.getString(_dayBalKey) ?? '') ?? balance;
    final dayPnl = balance - dayBal;

    // Detect a close of OUR auto trade since the last tick: update the
    // loss streak + start the cooldown.
    final openId = prefs.getString(_openIdKey);
    if (openId != null &&
        !openPositions.any((p) => '${p['id']}' == openId)) {
      final entryEquity = prefs.getDouble(_openEquityKey) ?? balance;
      final losses = (prefs.getInt(_lossesKey) ?? 0);
      if (balance < entryEquity - 0.005) {
        await prefs.setInt(_lossesKey, losses + 1);
        await AiLog.add('trade',
            'Auto position closed at a loss (streak ${losses + 1})');
      } else {
        await prefs.setInt(_lossesKey, 0);
        await AiLog.add('trade', 'Auto position closed at a profit');
      }
      await prefs.remove(_openIdKey);
      await prefs.remove(_openEquityKey);
      await prefs.setString(_cooldownKey,
          now.add(cooldownAfterClose).toIso8601String());
      if ((prefs.getInt(_lossesKey) ?? 0) >= maxConsecutiveLosses) {
        await _pause(prefs, '2 consecutive losses - paused for today');
        return 'Paused: 2 consecutive losses';
      }
    }

    // Rails that stop opening.
    if ((prefs.getInt(_countKey) ?? 0) >= maxTradesPerDay) {
      await _pause(prefs, 'Daily limit of $maxTradesPerDay auto trades reached');
      return 'Paused: daily trade limit';
    }
    if (dayBal > 0 && dayPnl <= -dailyDrawdownPct * dayBal) {
      await _pause(prefs, 'Daily drawdown limit (-2%) hit');
      return 'Paused: daily drawdown limit';
    }
    if (openPositions.isNotEmpty) {
      // One position at a time for the AI: never stack.
      if (openId == null) {
        await AiLog.add('decision',
            'Skipped: a position is already open (not opened by AI)');
      }
      return 'Position already open - holding off';
    }

    // --- ask the brain ---
    final snapshot = MarketSnapshot(
      bid: quote.$1,
      ask: quote.$2,
      candles: candles,
      openPosition: null,
      tradesToday: prefs.getInt(_countKey) ?? 0,
      dayPnl: dayPnl,
      balance: balance,
    );
    AiDecision d;
    try {
      d = await (brain ?? GroqBrain()).decide(snapshot);
    } on BrainException catch (e) {
      await _pause(prefs, 'AI unavailable (${e.message})');
      return 'Paused: ${e.message}';
    }

    await AiLog.add('decision',
        '${d.action.toUpperCase()} (${d.confidence}) - ${d.reason.isEmpty ? 'no reason given' : d.reason}');

    if (!d.isTrade) return 'Brain says ${d.action.toUpperCase()} - no trade';

    // --- execute within the rails ---
    final ref = d.action == 'buy' ? quote.$2 : quote.$1;
    final sizePct = prefs.getDouble(_sizeKey) ?? d.sizePct;
    final qty = ((balance * sizePct / 100) / ref);
    final opened = await _paperOpen(pin, d.action, ref, qty, d.tp, d.sl);
    if (opened == null) {
      await AiLog.add('error', 'Order rejected by the paper backend');
      return 'Order rejected';
    }
    await prefs.setInt(_countKey, (prefs.getInt(_countKey) ?? 0) + 1);
    await prefs.setString(_openIdKey, opened);
    await prefs.setDouble(_openEquityKey, balance);
    final msg =
        '${d.action == 'buy' ? 'Bought' : 'Sold'} ${qty.toStringAsFixed(2)} oz @ ${ref.toStringAsFixed(2)} - TP ${d.tp!.toStringAsFixed(2)}, SL ${d.sl!.toStringAsFixed(2)}. ${d.reason}';
    await AiLog.add('trade', msg);
    await showForegroundNotification('Oro AI traded', msg);
    return msg;
  }

  static Future<void> _pause(SharedPreferences prefs, String reason) async {
    await prefs.setString(_pauseKey, reason);
    await AiLog.add('pause', reason);
    await showForegroundNotification('Oro AI paused', reason);
  }

  // --- network helpers (mirrors of notifications.dart workers) ---

  static const _sbUrl = 'https://ncaialkmxhbtarmhoiei.supabase.co';
  // Same publishable anon key the rest of the app uses - the legacy JWT
  // anon key was rotated out at Supabase and 401s.
  static const _sbKey = 'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';

  static Future<(double, double)?> _fetchQuote() async {
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
      final ts = ((list.first as Map)['ts'] as num?)?.toInt();
      if (ts != null &&
          DateTime.now().millisecondsSinceEpoch - ts > 5 * 60 * 1000) {
        return null; // stale tick: market break or a frozen feed
      }
      final p = prices.first as Map;
      final bid = (p['bid'] as num?)?.toDouble();
      final ask = (p['ask'] as num?)?.toDouble();
      if (bid == null || ask == null || bid <= 0 || ask <= 0) return null;
      return (bid, ask);
    } catch (_) {
      return null;
    }
  }

  /// Returns (state, error). error is a precise reason when state is null
  /// so the AI tab can say WHAT failed instead of a bare "could not read".
  static Future<(Map<String, dynamic>?, String?)> _paperState(
      String pin) async {
    try {
      final r = await http
          .post(Uri.parse('$_sbUrl/rest/v1/rpc/paper_state'),
              headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
              body: jsonEncode({'p': pin}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 400 && r.body.contains('bad pin')) {
        return (null, 'PIN rejected - unlock the app again to refresh it');
      }
      if (r.statusCode >= 400) {
        return (null, 'server error ${r.statusCode}');
      }
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return (j, null);
      return (null, 'unexpected reply from server');
    } catch (_) {
      return (null, 'no connection to trading server');
    }
  }

  /// Opens a paper position through the same RPC as manual trades.
  /// Returns the new trade id, or null on failure.
  static Future<String?> _paperOpen(String pin, String dir, double price,
      double qty, double? tp, double? sl) async {
    try {
      final r = await http
          .post(Uri.parse('$_sbUrl/rest/v1/rpc/paper_open'),
              headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'p': pin,
                'd': dir,
                'price': price,
                'q': qty,
                'target': tp,
                'stop': sl
              }))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 400) return null;
      final (state, _) = await _paperState(pin);
      final positions =
          List<Map<String, dynamic>>.from(state?['positions'] as List? ?? []);
      // paper_state returns full history; only an OPEN position can be ours.
      final open = positions.where((p) => p['status'] == 'open').toList();
      if (open.isEmpty) return null;
      // Newest open position = ours (we only open when none exist).
      return '${open.last['id']}';
    } catch (_) {
      return null;
    }
  }
}
