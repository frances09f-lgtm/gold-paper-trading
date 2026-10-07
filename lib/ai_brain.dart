/// Oro AI brain: real model calls to Groq (free tier) that decide
/// buy/sell/hold from live market data. No fake analysis - if the key is
/// missing or the call fails, the caller pauses auto mode honestly.
///
/// Background-safe: pure Dart + http, no Flutter UI imports, so the
/// WorkManager isolate can use it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'usage_reporter.dart';

import 'chart/indicators.dart';
import 'market_data/models.dart';

class AiConfig {
  /// Groq API key from the build environment (--dart-define=GROQ_API_KEY),
  /// never hard-coded. Empty means auto-trade cannot run - say so.
  static const groqApiKey = String.fromEnvironment('GROQ_API_KEY');
  static const model =
      String.fromEnvironment('GROQ_MODEL', defaultValue: 'openai/gpt-oss-120b');
  static const fallbackModel = 'openai/gpt-oss-20b';
}

/// Everything the model sees: real market data + account context.
class MarketSnapshot {
  final double bid;
  final double ask;
  final List<Candle> candles; // oldest-first, ~50 recent candles
  final String? openPosition; // human summary of the one open position
  final int tradesToday;
  final double dayPnl;
  final double balance;

  const MarketSnapshot({
    required this.bid,
    required this.ask,
    required this.candles,
    required this.openPosition,
    required this.tradesToday,
    required this.dayPnl,
    required this.balance,
  });

  double get mid => (bid + ask) / 2;
}

class AiDecision {
  final String action; // 'buy' | 'sell' | 'hold'
  final String confidence; // 'low' | 'medium' | 'high'
  final double? sl; // absolute price, after clamping
  final double? tp; // absolute price, after clamping
  final double sizePct; // 1..25, % of paper balance as notional
  final String reason;
  final String raw; // raw model output, kept for the AI log

  const AiDecision({
    required this.action,
    required this.confidence,
    required this.sl,
    required this.tp,
    required this.sizePct,
    required this.reason,
    required this.raw,
  });

  bool get isTrade =>
      (action == 'buy' || action == 'sell') && confidence != 'low';

  static AiDecision hold(String reason, {String raw = ''}) => AiDecision(
      action: 'hold',
      confidence: 'low',
      sl: null,
      tp: null,
      sizePct: 10,
      reason: reason,
      raw: raw);
}

/// Chart advice (user-facing "Advice" button): a read of support/
/// resistance and recent structure. ADVICE ONLY - nothing here places
/// trades; the UI shows it as possibilities, not financial advice.
class AdviceResult {
  final String verdict; // 'buy' | 'sell' | 'wait'
  final String reasons;
  final String raw;
  const AdviceResult(this.verdict, this.reasons, {this.raw = ''});
}

class BrainException implements Exception {
  final String message;
  const BrainException(this.message);
  @override
  String toString() => message;
}

/// MACD line (12,26,9) values - same convention as the chart.
List<double> macdLine(List<Candle> candles) {
  final e12 = ema(candles, 12);
  final e26 = ema(candles, 26);
  final n = e12.length < e26.length ? e12.length : e26.length;
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    out.add(e12[e12.length - n + i] - e26[e26.length - n + i]);
  }
  return out;
}

/// Average true range (14) - used for sane stop distances.
double? atr(List<Candle> candles, int period) {
  if (candles.length < period + 1) return null;
  final trs = <double>[];
  for (var i = candles.length - period; i < candles.length; i++) {
    final c = candles[i];
    final prevClose = candles[i - 1].close;
    final tr = [
      c.high - c.low,
      (c.high - prevClose).abs(),
      (c.low - prevClose).abs()
    ].reduce((a, b) => a > b ? a : b);
    trs.add(tr);
  }
  return trs.reduce((a, b) => a + b) / trs.length;
}

String buildPrompt(MarketSnapshot s) {
  final b = StringBuffer();
  b.writeln('Instrument: XAU/USD (gold spot).');
  b.writeln('Live quote: bid ${s.bid.toStringAsFixed(2)}, ask ${s.ask.toStringAsFixed(2)}.');
  final cs = s.candles;
  if (cs.length >= 50) {
    final s20 = sma(cs, 20).last;
    final e50 = ema(cs, 50).last;
    final r14 = rsi(cs, 14).last;
    final macd = macdLine(cs);
    final a = atr(cs, 14);
    b.writeln('15-minute candles, last ${cs.length}:');
    b.writeln('  SMA20 ${s20.toStringAsFixed(2)} | EMA50 ${e50.toStringAsFixed(2)} | RSI14 ${r14.toStringAsFixed(1)} | MACD ${macd.isEmpty ? 'n/a' : macd.last.toStringAsFixed(2)} | ATR14 ${a?.toStringAsFixed(2) ?? 'n/a'}');
    // Recent structure, same read as the in-app bias panel.
    final n = cs.length;
    final last = cs.sublist(n - 10);
    final prev = cs.sublist(n - 20, n - 10);
    double hiOf(List<Candle> l) => l.fold(-double.infinity, (x, c) => x > c.high ? x : c.high);
    double loOf(List<Candle> l) => l.fold(double.infinity, (x, c) => x < c.low ? x : c.low);
    b.writeln('  Structure: last10 high ${hiOf(last).toStringAsFixed(1)} low ${loOf(last).toStringAsFixed(1)} | prev10 high ${hiOf(prev).toStringAsFixed(1)} low ${loOf(prev).toStringAsFixed(1)}');
    b.writeln('  Last 12 candles (time,o,h,l,c):');
    for (final c in cs.sublist(n - 12)) {
      b.writeln('  ${c.time.toIso8601String()},${c.open.toStringAsFixed(2)},${c.high.toStringAsFixed(2)},${c.low.toStringAsFixed(2)},${c.close.toStringAsFixed(2)}');
    }
  } else {
    b.writeln('Only ${cs.length} candles available - thin data.');
  }
  b.writeln('Paper account: balance \$${s.balance.toStringAsFixed(2)}, PnL today ${s.dayPnl.toStringAsFixed(2)}, auto trades today ${s.tradesToday}.');
  b.writeln('Open position: ${s.openPosition ?? 'none'}.');
  return b.toString();
}

const _systemPrompt =
    'You are the trading brain of a paper-trading app for XAU/USD. '
    'Analyse the data and reply with ONLY a JSON object, no prose: '
    '{"action":"buy"|"sell"|"hold","confidence":"low"|"medium"|"high",'
    '"stop_loss":number,"take_profit":number,"size_pct":number,"reason":"one short sentence"}. '
    'stop_loss and take_profit are absolute prices for the suggested side. '
    'size_pct is the share of the paper balance to use as notional (1-25). '
    'This is a paper account for learning to trade. Choose hold only when '
    'the picture is genuinely unclear or mixed; when the data supports a '
    'reasonable setup with defined risk, take the trade with medium or '
    'high confidence. Never invent data.';

/// Parse + validate + clamp the model output against real prices.
/// Malformed output becomes a hold - the engine never acts on garbage.
AiDecision parseDecision(String content, {required double buyRef, required double sellRef}) {
  String jsonText;
  final start = content.indexOf('{');
  final end = content.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return AiDecision.hold('Model returned no JSON', raw: content);
  }
  jsonText = content.substring(start, end + 1);
  Map<String, dynamic> j;
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      return AiDecision.hold('Model returned non-object JSON', raw: content);
    }
    j = decoded;
  } catch (_) {
    return AiDecision.hold('Model returned unparseable JSON', raw: content);
  }

  var action = (j['action']?.toString().toLowerCase() ?? 'hold');
  if (action != 'buy' && action != 'sell') action = 'hold';
  var confidence = (j['confidence']?.toString().toLowerCase() ?? 'low');
  if (confidence != 'medium' && confidence != 'high') confidence = 'low';
  final reason = j['reason']?.toString() ?? '';
  var sizePct = (j['size_pct'] as num?)?.toDouble() ?? 10;
  if (sizePct < 1) sizePct = 1;
  if (sizePct > 25) sizePct = 25;

  if (action == 'hold' || confidence == 'low') {
    return AiDecision.hold(reason.isEmpty ? 'Model says hold' : reason, raw: content);
  }

  final ref = action == 'buy' ? buyRef : sellRef;
  var sl = (j['stop_loss'] as num?)?.toDouble();
  var tp = (j['take_profit'] as num?)?.toDouble();
  final dirUp = action == 'buy';

  // Clamp the stop into 0.3%..2.0% of entry, on the correct side.
  const minStop = 0.003, maxStop = 0.02;
  double defaultStop() => dirUp ? ref * (1 - 0.006) : ref * (1 + 0.006);
  if (sl == null || (dirUp ? sl >= ref : sl <= ref)) {
    sl = defaultStop();
  } else {
    final dist = (ref - sl).abs() / ref;
    if (dist < minStop) sl = dirUp ? ref * (1 - minStop) : ref * (1 + minStop);
    if (dist > maxStop) sl = dirUp ? ref * (1 - maxStop) : ref * (1 + maxStop);
  }
  final riskDist = (ref - sl).abs();
  // Take profit: at least 1.5x the risk distance, on the correct side.
  if (tp == null ||
      (dirUp ? tp <= ref : tp >= ref) ||
      (tp - ref).abs() < 1.5 * riskDist) {
    tp = dirUp ? ref + 1.5 * riskDist : ref - 1.5 * riskDist;
  }

  return AiDecision(
    action: action,
    confidence: confidence,
    sl: sl,
    tp: tp,
    sizePct: sizePct,
    reason: reason,
    raw: content,
  );
}

const _adviceSystemPrompt =
    'You are the chart-analysis brain of a gold (XAU/USD) paper-trading app. '
    'The user asks for your read of the chart - this is advice only and no '
    'order will be placed from it. Reply with ONLY a minified JSON object, '
    'no prose: {"verdict":"buy"|"sell"|"wait","reasons":"2-3 short sentences"}. '
    'Base the verdict on the support/resistance levels and recent structure '
    'in the data. Choose wait when the picture is unclear. Never invent data.';

/// Prompt for the Advice button: same real market data as the auto-trade
/// brain, plus swing support/resistance and the user's drawn chart levels.
String buildAdvicePrompt({
  required double bid,
  required double ask,
  required List<Candle> candles,
  required List<double> drawnLevels,
}) {
  final b = StringBuffer();
  b.writeln('Instrument: XAU/USD (gold spot).');
  b.writeln(
      'Live quote: bid ${bid.toStringAsFixed(2)}, ask ${ask.toStringAsFixed(2)}.');
  final cs = candles;
  if (cs.length >= 50) {
    final s20 = sma(cs, 20).last;
    final e50 = ema(cs, 50).last;
    final r14 = rsi(cs, 14).last;
    final macd = macdLine(cs);
    final a = atr(cs, 14);
    b.writeln('15-minute candles, last ${cs.length}:');
    b.writeln(
        '  SMA20 ${s20.toStringAsFixed(2)} | EMA50 ${e50.toStringAsFixed(2)} | RSI14 ${r14.toStringAsFixed(1)} | MACD ${macd.isEmpty ? 'n/a' : macd.last.toStringAsFixed(2)} | ATR14 ${a?.toStringAsFixed(2) ?? 'n/a'}');
    final n = cs.length;
    final last = cs.sublist(n - 10);
    final prev = cs.sublist(n - 20, n - 10);
    double hiOf(List<Candle> l) =>
        l.fold(-double.infinity, (x, c) => x > c.high ? x : c.high);
    double loOf(List<Candle> l) =>
        l.fold(double.infinity, (x, c) => x < c.low ? x : c.low);
    b.writeln(
        '  Structure: last10 high ${hiOf(last).toStringAsFixed(1)} low ${loOf(last).toStringAsFixed(1)} | prev10 high ${hiOf(prev).toStringAsFixed(1)} low ${loOf(prev).toStringAsFixed(1)}');
    // Swing support/resistance from the last 48 candles.
    final win = cs.sublist(n >= 48 ? n - 48 : 0);
    final swingHi = hiOf(win);
    final swingLo = loOf(win);
    b.writeln(
        '  Swing range (last ${win.length} candles): resistance ${swingHi.toStringAsFixed(1)}, support ${swingLo.toStringAsFixed(1)}.');
    b.writeln('  Last 12 candles (time,o,h,l,c):');
    for (final c in cs.sublist(n - 12)) {
      b.writeln(
          '  ${c.time.toIso8601String()},${c.open.toStringAsFixed(2)},${c.high.toStringAsFixed(2)},${c.low.toStringAsFixed(2)},${c.close.toStringAsFixed(2)}');
    }
  } else {
    b.writeln('Only ${cs.length} candles available - thin data.');
  }
  if (drawnLevels.isNotEmpty) {
    final sorted = [...drawnLevels]..sort();
    b.writeln(
        'User-drawn chart levels: ${sorted.map((e) => e.toStringAsFixed(1)).join(', ')}.');
  }
  b.writeln('Give your read: buy, sell, or wait, with short reasons.');
  return b.toString();
}

/// Parse the advice reply. Anything malformed becomes a wait with an
/// honest note - the UI never shows invented analysis.
AdviceResult parseAdvice(String content) {
  final start = content.indexOf('{');
  final end = content.lastIndexOf('}');
  Map<String, dynamic>? j;
  if (start >= 0 && end > start) {
    try {
      final decoded = jsonDecode(content.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) j = decoded;
    } catch (_) {}
  }
  if (j == null) {
    return AdviceResult('wait', 'Could not read the AI answer.', raw: content);
  }
  var v = j['verdict']?.toString().toLowerCase() ?? 'wait';
  if (v != 'buy' && v != 'sell') v = 'wait';
  final reasons = j['reasons']?.toString().trim() ?? '';
  return AdviceResult(
      v, reasons.isEmpty ? 'No reasons given.' : reasons,
      raw: content);
}

class GroqBrain {
  final http.Client _client;
  GroqBrain({http.Client? client}) : _client = client ?? http.Client();

  Future<AiDecision> decide(MarketSnapshot s) async {
    if (AiConfig.groqApiKey.isEmpty) {
      throw const BrainException(
          'GROQ_API_KEY is not configured in this build');
    }
    final user = buildPrompt(s);
    var content = await _call(AiConfig.model, user);
    content ??= await _call(AiConfig.fallbackModel, user); // rate-limit fallback
    if (content == null) {
      throw const BrainException('Groq call failed or rate-limited');
    }
    return parseDecision(content, buyRef: s.ask, sellRef: s.bid);
  }

  /// Chart advice for the Advice button. Real model call, real data,
  /// advice only - this never touches AutoTrade or paper positions.
  Future<AdviceResult> advise({
    required double bid,
    required double ask,
    required List<Candle> candles,
    List<double> drawnLevels = const [],
  }) async {
    if (AiConfig.groqApiKey.isEmpty) {
      throw const BrainException('GROQ_API_KEY is not configured in this build');
    }
    final user = buildAdvicePrompt(
        bid: bid, ask: ask, candles: candles, drawnLevels: drawnLevels);
    var content = await _call(AiConfig.model, user, system: _adviceSystemPrompt);
    content ??=
        await _call(AiConfig.fallbackModel, user, system: _adviceSystemPrompt);
    if (content == null) {
      throw const BrainException('Groq call failed or rate-limited');
    }
    return parseAdvice(content);
  }

  Future<String?> _call(String model, String userPrompt,
      {String? system}) async {
    try {
      final r = await _client
          .post(Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
              headers: {
                'Authorization': 'Bearer ${AiConfig.groqApiKey}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'model': model,
                'messages': [
                  {'role': 'system', 'content': system ?? _systemPrompt},
                  {'role': 'user', 'content': userPrompt},
                ],
                'temperature': 0.2,
                'max_tokens': 3000,
                // gpt-oss is a reasoning model: medium effort gives a real
                // analysis; low effort answered "hold" almost always.
                'reasoning_effort': 'medium',
              }))
          .timeout(const Duration(seconds: 30));
      UsageReporter.report('ai_request', {'model': model, 'ok': r.statusCode == 200});
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      final choices = j['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      return (choices.first as Map)['message']?['content']?.toString();
    } catch (_) {
      UsageReporter.report('ai_request', {'model': model, 'ok': false});
      return null;
    }
  }
}
