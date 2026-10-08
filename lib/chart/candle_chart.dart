import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis.dart';
import '../market_data/models.dart';
import 'indicators.dart';

/// Real candle chart (stage b). Renders ONLY candles that came from a
/// historical candle service - never synthetic or placeholder bars.

typedef CandleLoader = Future<List<Candle>> Function(String interval);

/// A user-drawn horizontal level (spec 9: named, stored locally, editable).
/// Default name is neutral - never claim a level IS support or resistance.
class DrawnLine {
  final double price;
  final String name;
  const DrawnLine(this.price, this.name);
}

/// A user-drawn trend line (spec 9), anchored by candle TIME + price so it
/// stays attached to the same market points as new candles arrive.
class TrendLine {
  final DateTime t1;
  final double p1;
  final DateTime t2;
  final double p2;
  const TrendLine(this.t1, this.p1, this.t2, this.p2);
}

class ChartInterval {
  final String code; // provider interval code
  final String label;
  final Duration refresh;
  const ChartInterval(this.code, this.label, this.refresh);
}

const intervals = [
  ChartInterval('1min', '1m', Duration(seconds: 15)),
  ChartInterval('15min', '15m', Duration(minutes: 5)),
  ChartInterval('1h', '1H', Duration(minutes: 15)),
  ChartInterval('4h', '4H', Duration(minutes: 30)),
  ChartInterval('1day', '1D', Duration(hours: 1)),
];

const tradeRanges = [
  ChartInterval('range:1H', '1H', Duration(minutes: 1)),
  ChartInterval('range:1D', '1D', Duration(minutes: 5)),
  ChartInterval('range:1W', '1W', Duration(minutes: 15)),
  ChartInterval('range:1M', '1M', Duration(hours: 1)),
  ChartInterval('range:3M', '3M', Duration(hours: 4)),
  ChartInterval('range:1Y', '1Y', Duration(hours: 12)),
];

class CandleChartPanel extends StatefulWidget {
  /// Loads real candles; may throw. When null, no candle source is
  /// configured and the panel says so instead of drawing fake bars.
  final CandleLoader? loader;

  /// Latest live price for the dashed last-price line (optional).
  final double? livePrice;

  /// Fullscreen mode: the chart body fills the available height instead
  /// of the fixed in-page height.
  final bool expand;
  final bool rangeMode;

  const CandleChartPanel({
    super.key,
    this.loader,
    this.livePrice,
    this.expand = false,
    this.rangeMode = false,
  });

  @override
  State<CandleChartPanel> createState() => CandleChartPanelState();
}

class CandleChartPanelState extends State<CandleChartPanel> {
  bool usingRange = false;
  int _loadGeneration = 0;
  ChartInterval interval = intervals[1]; // 15m default
  List<Candle> candles = [];
  int loadedAt = 0;
  bool loading = false;
  String? error;
  int? selected; // crosshair candle index
  Timer? _timer;
  bool biasExpanded = false;
  bool smaOn = true;
  bool emaOn = true;
  bool sma200On = false;
  bool rsiOn = false;
  bool macdOn = false;
  final Set<int> extraEmas = {};
  bool bollingerOn = false;
  bool drawMode = false;
  bool trendMode = false;
  final List<DrawnLine> hLines = []; // user-drawn named price levels
  final List<TrendLine> trendLines = []; // user-drawn trend lines
  TrendLine? pendingTrend; // first anchor set, waiting for the second tap
  bool fibMode = false;
  int? _dragLineIdx; // hLine being drag-moved in Draw mode
  final List<TrendLine> fibs = []; // fibonacci retracements (2 anchors each)
  TrendLine? pendingFib;

  // Chart navigation (user request): pinch to zoom, horizontal drag to
  // scroll back through candles. scrollCandles = bars scrolled back from
  // the newest; visibleOverride = zoomed bar count (null = fit all).
  double scrollCandles = 0;
  int? visibleOverride;
  double _scaleStartVC = 0;
  double _panStartScroll = 0;
  static const double rightPad = 52.0;

  int get _vc {
    final n = candles.length;
    if (n == 0) return 1;
    final v = visibleOverride ?? n;
    if (v > n) return n;
    return v < 15 ? (n < 15 ? n : 15) : v;
  }

  int get _fv {
    final n = candles.length;
    if (n == 0) return 0;
    final maxFv = n - _vc;
    var fv = n - _vc - scrollCandles.round();
    if (fv < 0) fv = 0;
    if (fv > maxFv) fv = maxFv < 0 ? 0 : maxFv;
    return fv;
  }

  /// Price range of the VISIBLE window (+ live price) - shared by the
  /// painter and every gesture mapper so they always agree.
  (double, double) _visiblePriceRange() {
    final n = candles.length;
    double hi = -double.infinity, lo = double.infinity;
    if (n > 0) {
      final fv = _fv, vc = _vc;
      for (int i = fv; i < (fv + vc < n ? fv + vc : n); i++) {
        final c = candles[i];
        hi = hi > c.high ? hi : c.high;
        lo = lo < c.low ? lo : c.low;
      }
    }
    if (widget.livePrice != null) {
      hi = hi > widget.livePrice! ? hi : widget.livePrice!;
      lo = lo < widget.livePrice! ? lo : widget.livePrice!;
    }
    return (hi, lo);
  }

  @override
  void initState() {
    super.initState();
    usingRange = widget.rangeMode;
    if (usingRange) interval = tradeRanges[1];
    _loadLines();
    _load();
    _armTimer();
  }

  /// Spec 9: drawn levels are stored locally (device), never on the server.
  Future<void> _loadLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_lines');
      final rawT = prefs.getString('tj_draw_trends');
      setState(() {
        if (raw != null) {
          final list = jsonDecode(raw) as List;
          hLines
            ..clear()
            ..addAll(
              list.map(
                (e) => DrawnLine(
                  (e['p'] as num).toDouble(),
                  e['n']?.toString() ?? 'Level',
                ),
              ),
            );
        }
        if (rawT != null) {
          final list = jsonDecode(rawT) as List;
          trendLines
            ..clear()
            ..addAll(
              list.map(
                (e) => TrendLine(
                  DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                  (e['p1'] as num).toDouble(),
                  DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                  (e['p2'] as num).toDouble(),
                ),
              ),
            );
        }
        final rawF = prefs.getString('tj_draw_fibs');
        if (rawF != null) {
          final list = jsonDecode(rawF) as List;
          fibs
            ..clear()
            ..addAll(
              list.map(
                (e) => TrendLine(
                  DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                  (e['p1'] as num).toDouble(),
                  DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                  (e['p2'] as num).toDouble(),
                ),
              ),
            );
        }
      });
    } catch (_) {}
  }

  Future<void> _saveFibs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_fibs',
        jsonEncode(
          fibs
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveTrends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_trends',
        jsonEncode(
          trendLines
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  bool get _hasDrawings =>
      hLines.isNotEmpty ||
      trendLines.isNotEmpty ||
      fibs.isNotEmpty ||
      pendingTrend != null ||
      pendingFib != null;

  /// Clear ALL chart drawings at once (user request): every drawn level,
  /// trend line and fib, including a half-placed anchor. Persisted copies
  /// are cleared too so they stay gone after restart.
  Future<void> _clearAllDrawings() async {
    setState(() {
      hLines.clear();
      trendLines.clear();
      fibs.clear();
      pendingTrend = null;
      pendingFib = null;
      _dragLineIdx = null;
    });
    await _saveLines();
    await _saveTrends();
    await _saveFibs();
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151A22),
        title: const Text(
          'Clear all drawings?',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: const Text(
          'This removes every drawn level, trend line and fib on the chart.',
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Clear',
              style: TextStyle(color: Color(0xFFF27EA9)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await _clearAllDrawings();
  }

  Future<void> _saveLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_lines',
        jsonEncode(hLines.map((e) => {'p': e.price, 'n': e.name}).toList()),
      );
    } catch (_) {}
  }

  /// Long-press near a drawn line: rename it (Support, Resistance, ...) or
  /// delete it (spec 9: create / edit / delete / rename).
  Future<void> _editLineAt(Offset pos, Size size) async {
    if (hLines.isEmpty || candles.isEmpty) return;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final range = hi - lo;
    final idx = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    if (idx < 0) {
      // no horizontal level near - try trend lines (pixel-space distance)
      final tIdx = _trendHit(pos, Size(size.width, plotH), hi, lo);
      if (tIdx < 0) {
        final fIdx = _fibHit(pos, Size(size.width, plotH), hi, lo);
        if (fIdx < 0) return;
        final delF = await showDialog<bool>(
          context: context,
          builder: (dCtx) => AlertDialog(
            backgroundColor: const Color(0xFF161B24),
            title: const Text(
              'Fibonacci retracement',
              style: TextStyle(fontSize: 16),
            ),
            content: const Text('Delete this fibonacci retracement?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dCtx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (delF == true) {
          setState(() => fibs.removeAt(fIdx));
          _saveFibs();
        }
        return;
      }
      final del = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          backgroundColor: const Color(0xFF161B24),
          title: const Text('Trend line', style: TextStyle(fontSize: 16)),
          content: const Text('Delete this trend line?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (del == true) {
        setState(() => trendLines.removeAt(tIdx));
        _saveTrends();
      }
      return;
    }
    final line = hLines[idx];
    final ctrl = TextEditingController(text: line.name);
    final act = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF161B24),
        title: Text(
          'Level at ${line.price.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Name (e.g. Support, Resistance)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, 'delete'),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF6B6B)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    setState(() {
      if (act == 'delete') {
        hLines.removeAt(idx);
      } else if (act == 'save') {
        hLines[idx] = DrawnLine(
          line.price,
          ctrl.text.trim().isEmpty ? 'Level' : ctrl.text.trim(),
        );
      }
    });
    _saveLines();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval.refresh, (_) => _load(quiet: true));
  }

  Future<void> _load({bool quiet = false}) async {
    final loader = widget.loader;
    if (loader == null) return;
    if (!quiet) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    final generation = ++_loadGeneration;
    try {
      final requested = interval.code;
      final raw = await loader(requested);
      final data = usingRange ? trimTradeRange(raw, requested) : raw;
      if (!mounted ||
          generation != _loadGeneration ||
          interval.code != requested)
        return;
      setState(() {
        candles = data;
        loadedAt = DateTime.now().millisecondsSinceEpoch;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        loading = false;
        // Keep the last real candles on screen; flag the error.
        error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _setInterval(ChartInterval iv) {
    if (iv.code == interval.code) return;
    setState(() {
      interval = iv;
      candles = [];
      selected = null;
      error = null;
    });
    _armTimer();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0E1116);
    const dim = Color(0xFF8A93A6);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF232A35)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'XAU/USD',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      PopupMenuButton<String>(
                        tooltip: 'Indicators',
                        onSelected: (v) => setState(() {
                          switch (v) {
                            case 'SMA20':
                              smaOn = !smaOn;
                              break;
                            case 'SMA200':
                              sma200On = !sma200On;
                              break;
                            case 'EMA50':
                              emaOn = !emaOn;
                              break;
                            case 'RSI14':
                              rsiOn = !rsiOn;
                              break;
                            case 'MACD':
                              macdOn = !macdOn;
                              break;
                            case 'BB20':
                              bollingerOn = !bollingerOn;
                              break;
                            default:
                              final n = int.parse(v.substring(3));
                              extraEmas.contains(n)
                                  ? extraEmas.remove(n)
                                  : extraEmas.add(n);
                          }
                        }),
                        itemBuilder: (_) => [
                          for (final item in <(String, String, bool)>[
                            ('SMA20', 'SMA 20', smaOn),
                            ('SMA200', 'SMA 200', sma200On),
                            ('EMA9', 'EMA 9', extraEmas.contains(9)),
                            ('EMA21', 'EMA 21', extraEmas.contains(21)),
                            ('EMA50', 'EMA 50', emaOn),
                            ('EMA200', 'EMA 200', extraEmas.contains(200)),
                            ('RSI14', 'RSI 14', rsiOn),
                            ('MACD', 'MACD 12/26/9', macdOn),
                            ('BB20', 'Bollinger 20 / 2', bollingerOn),
                          ])
                            CheckedPopupMenuItem(
                              value: item.$1,
                              checked: item.$3,
                              child: Text(item.$2),
                            ),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Indicators',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                color: Colors.white,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                      _indChip(
                        'Draw',
                        drawMode,
                        const Color(0xFF5EE0A0),
                        () => setState(() {
                          drawMode = !drawMode;
                          if (drawMode) {
                            trendMode = false;
                            fibMode = false;
                          }
                        }),
                      ),
                      _indChip(
                        'Trend',
                        trendMode,
                        const Color(0xFF6FD3E0),
                        () => setState(() {
                          trendMode = !trendMode;
                          if (trendMode) {
                            drawMode = false;
                            fibMode = false;
                          }
                          pendingTrend = null;
                        }),
                      ),
                      _indChip(
                        'Fib',
                        fibMode,
                        const Color(0xFFFFD166),
                        () => setState(() {
                          fibMode = !fibMode;
                          if (fibMode) {
                            drawMode = false;
                            trendMode = false;
                          }
                          pendingFib = null;
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFF5C242),
                  ),
                ),
              if (_hasDrawings) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: _confirmClearAll,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.delete_sweep,
                      size: 18,
                      color: Color(0xFFF27EA9),
                    ),
                  ),
                ),
              ],
              if (!widget.expand) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FullscreenChartPage(
                        loader: widget.loader,
                        livePrice: widget.livePrice,
                        rangeMode: usingRange,
                      ),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.fullscreen,
                      size: 18,
                      color: Color(0xFF8A93A6),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (widget.rangeMode)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  usingRange = !usingRange;
                  _setInterval(usingRange ? tradeRanges[1] : intervals[0]);
                },
                child: Text(usingRange ? 'Candle intervals' : 'History ranges'),
              ),
            ),
          if (!usingRange) ...[
            Row(
              children: [
                ...(usingRange ? tradeRanges : intervals).map((iv) {
                  final on = iv.code == interval.code;
                  return GestureDetector(
                    onTap: () => _setInterval(iv),
                    child: Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: on
                            ? const Color(0xFFF5C242)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: on
                              ? const Color(0xFFF5C242)
                              : const Color(0xFF2A3140),
                        ),
                      ),
                      child: Text(
                        iv.label,
                        style: TextStyle(
                          color: on ? Colors.black : const Color(0xFF8A93A6),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
          const SizedBox(height: 6),
          _legend(dim),
          const SizedBox(height: 4),
          if (widget.expand)
            Expanded(child: _body())
          else
            SizedBox(
              height:
                  220 +
                  ((rsiOn && candles.length > 14) ? 60 : 0) +
                  ((macdOn && candles.length > 33) ? 60 : 0),
              child: _body(),
            ),
          if (usingRange) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                ...(usingRange ? tradeRanges : intervals).map((iv) {
                  final on = iv.code == interval.code;
                  return GestureDetector(
                    onTap: () => _setInterval(iv),
                    child: Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: on
                            ? const Color(0xFFF5C242)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: on
                              ? const Color(0xFFF5C242)
                              : const Color(0xFF2A3140),
                        ),
                      ),
                      child: Text(
                        iv.label,
                        style: TextStyle(
                          color: on ? Colors.black : const Color(0xFF8A93A6),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${tradeRangeDuration(interval.code).inHours < 24 ? "1-hour" : "${tradeRangeDuration(interval.code).inDays}-day"} window ending at latest returned candle · ${tradeRangeSpec(interval.code).$1} bars',
              style: const TextStyle(color: Color(0xFF8A93A6), fontSize: 10),
            ),
            if (candles.length >= 2 && candles.first.close != 0)
              Text(
                '${interval.label} selected · available change ${(candles.last.close - candles.first.close) >= 0 ? '+' : ''}${(candles.last.close - candles.first.close).toStringAsFixed(2)} (${((candles.last.close - candles.first.close) / candles.first.close * 100).toStringAsFixed(2)}%) over ${candles.length} available candles',
                style: const TextStyle(color: Color(0xFF8A93A6), fontSize: 10),
              ),
          ],
          if (candles.length >= 50) _biasStrip(),
        ],
      ),
    );
  }

  /// Trend bias strip (spec: S/R + trend readout). Rule-based read of the
  /// candles and drawn levels already on the chart - reasons listed, never
  /// a prediction.
  Widget _biasStrip() {
    const green = Color(0xFF5EE0A0);
    const red = Color(0xFFFF6B6B);
    const dim = Color(0xFF8A93A6);
    final r = analyzeBias(candles, hLines.map((e) => e.price).toList());
    final color = r.bias == TrendBias.bullish
        ? green
        : r.bias == TrendBias.bearish
        ? red
        : dim;
    final label = r.bias == TrendBias.bullish
        ? 'Bullish'
        : r.bias == TrendBias.bearish
        ? 'Bearish'
        : 'Neutral';
    return GestureDetector(
      onTap: () => setState(() => biasExpanded = !biasExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: color),
              const SizedBox(width: 6),
              const Text(
                'Trend bias: ',
                style: TextStyle(color: dim, fontSize: 11),
              ),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(
                biasExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: dim,
              ),
            ],
          ),
          if (biasExpanded) ...[
            const SizedBox(height: 4),
            for (final f in r.factors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.score > 0 ? '+' : (f.score < 0 ? '-' : '·'),
                      style: TextStyle(
                        color: f.score > 0 ? green : (f.score < 0 ? red : dim),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        f.text,
                        style: const TextStyle(
                          color: Color(0xFFB9C0CE),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              'Rule-based read of the current chart. Not a prediction.',
              style: TextStyle(
                color: dim,
                fontSize: 10,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _indChip(String label, bool on, Color color, VoidCallback tap) =>
      GestureDetector(
        onTap: tap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? color : const Color(0xFF2A3140)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: on ? color : const Color(0xFF8A93A6),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  Widget _legend(Color dim) {
    Candle? c;
    if (selected != null && candles.isNotEmpty) {
      c = candles[selected!.clamp(0, candles.length - 1)];
    } else if (candles.isNotEmpty) {
      c = candles.last;
    }
    if (error != null) {
      return Text(
        error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFE0654F), fontSize: 11),
      );
    }
    if (c == null) {
      return Text(
        widget.loader == null
            ? 'Candle feed not configured. Add your Twelve Data key in API settings.'
            : 'Loading real candles...',
        style: TextStyle(color: dim, fontSize: 11),
      );
    }
    final up = c.close >= c.open;
    final col = up ? const Color(0xFF2EC27E) : const Color(0xFFE0654F);
    String f(double v) => v.toStringAsFixed(2);
    return Text(
      'O ${f(c.open)}  H ${f(c.high)}  L ${f(c.low)}  C ${f(c.close)}',
      style: TextStyle(color: col, fontSize: 11, fontFamily: 'Roboto'),
    );
  }

  Widget _body() {
    if (widget.loader == null) {
      return const Center(
        child: Text(
          'No candle source configured.\nReal data only - no demo bars.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    if (candles.isEmpty && loading) {
      return const Center(
        child: Text(
          'Fetching candles from Twelve Data...',
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    if (candles.isEmpty) {
      // The legend above the chart already shows the error detail.
      return const Center(
        child: Text(
          'No candles returned',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, cons) {
        return GestureDetector(
          // Draw mode keeps pan for drag-moving levels; outside Draw, a
          // one-finger drag scrolls the chart and pinch zooms it.
          onPanDown: drawMode
              ? (d) => _dragLineStart(
                  d.localPosition,
                  Size(cons.maxWidth, cons.maxHeight),
                )
              : null,
          onPanUpdate: drawMode
              ? (d) => _dragLineUpdate(
                  d.localPosition,
                  Size(cons.maxWidth, cons.maxHeight),
                )
              : null,
          onPanEnd: drawMode ? (_) => _dragLineEnd() : null,
          onScaleStart: drawMode
              ? null
              : (d) {
                  _panStartScroll = scrollCandles;
                  _scaleStartVC = _vc.toDouble();
                },
          onScaleUpdate: drawMode
              ? null
              : (d) {
                  final n = candles.length;
                  if (n == 0) return;
                  if (d.pointerCount >= 2) {
                    setState(() {
                      final v = (_scaleStartVC / d.scale).round();
                      visibleOverride = v < 15 ? 15 : (v > n ? n : v);
                    });
                  } else {
                    final plotW = cons.maxWidth - 52.0;
                    final step = plotW / _vc;
                    if (step <= 0) return;
                    setState(() {
                      final maxScroll = (n - _vc) > 0
                          ? (n - _vc).toDouble()
                          : 0.0;
                      scrollCandles =
                          (_panStartScroll - d.focalPointDelta.dx / step).clamp(
                            0.0,
                            maxScroll,
                          );
                    });
                  }
                },
          onTapDown: (d) {
            if (trendMode) {
              _trendAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else if (fibMode) {
              _fibAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else {
              _pick(d.localPosition, cons.maxWidth);
            }
          },
          onTapUp: (d) {
            // Draw-mode add/remove lives on tap-UP so a drag-move (pan wins
            // the arena) never deletes the line being moved.
            if (drawMode) {
              _drawAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            }
          },
          onLongPressStart: (d) {
            _editLineAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
          },
          child: CustomPaint(
            size: Size(cons.maxWidth, cons.maxHeight),
            painter: CandlePainter(
              candles: candles,
              firstVisible: _fv,
              visibleCount: _vc,
              livePrice: widget.livePrice,
              selected: selected,
              hLines: hLines,
              trendLines: trendLines,
              pendingTrend: pendingTrend,
              fibs: fibs,
              pendingFib: pendingFib,
              extraEmas: {for (final p in extraEmas) p: ema(candles, p)},
              bands: bollingerOn ? bollinger(candles) : null,
              sma: smaOn ? sma(candles, 20) : null,
              sma200: sma200On ? sma(candles, 200) : null,
              smaPeriod: 20,
              ema: emaOn ? ema(candles, 50) : null,
              emaPeriod: 50,
              rsi: rsiOn ? rsi(candles, 14) : null,
              macdLine: macdOn ? macd(candles).$1 : null,
              macdSignal: macdOn ? macd(candles).$2 : null,
              macdHist: macdOn ? macd(candles).$3 : null,
              rsiPeriod: 14,
            ),
          ),
        );
      },
    );
  }

  void _pick(Offset pos, double width) {
    final plotW = width - rightPad;
    if (plotW <= 0 || candles.isEmpty) return;
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    setState(() => selected = i);
  }

  /// Index of a trend line within ~10px of the tap (pixel space), else -1.
  int _trendHit(Offset pos, Size plotSize, double hi, double lo) {
    if (trendLines.isEmpty || candles.length < 2) return -1;
    final plotW = plotSize.width - rightPad;
    final plotH = plotSize.height;
    final n = candles.length;
    double yOf(double v) => plotH * (1 - (v - lo) / (hi - lo));
    double idxAt(DateTime t) {
      final t0 = candles.first.time.millisecondsSinceEpoch;
      final tN = candles.last.time.millisecondsSinceEpoch;
      if (tN == t0) return 0;
      return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
    }

    final stepI = plotW / _vc;
    for (int k = 0; k < trendLines.length; k++) {
      final l = trendLines[k];
      final x1 = stepI * (idxAt(l.t1) - _fv + 0.5);
      final x2 = stepI * (idxAt(l.t2) - _fv + 0.5);
      if ((x2 - x1).abs() < 1e-6) continue;
      final y1 = yOf(l.p1), y2 = yOf(l.p2);
      final m = (y2 - y1) / (x2 - x1);
      final yAtTap = y1 + m * (pos.dx - x1);
      if ((yAtTap - pos.dy).abs() < 10) return k;
    }
    return -1;
  }

  /// Trend mode: first tap anchors one end (candle time + price), second
  /// tap completes the line. Anchored by time so it tracks the market.
  void _trendAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH || pos.dx < 0 || pos.dx > plotW) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    final t = candles[i].time;
    setState(() {
      final p = pendingTrend;
      if (p == null) {
        pendingTrend = TrendLine(t, price, t, price);
      } else {
        if (t == p.t1) return; // same candle - ignore
        trendLines.add(TrendLine(p.t1, p.p1, t, price));
        pendingTrend = null;
        _saveTrends();
      }
    });
  }

  /// Index of a fib whose level line passes within ~10px of the tap.
  int _fibHit(Offset pos, Size plotSize, double hi, double lo) {
    if (fibs.isEmpty) return -1;
    const fibFs = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];
    final plotH = plotSize.height;
    double yOf(double v) => plotH * (1 - (v - lo) / (hi - lo));
    for (int k = 0; k < fibs.length; k++) {
      final f = fibs[k];
      for (final frac in fibFs) {
        final price = f.p2 + (f.p1 - f.p2) * frac;
        if ((yOf(price) - pos.dy).abs() < 10) return k;
      }
    }
    return -1;
  }

  /// Fib mode: first tap anchors one swing point, second tap completes the
  /// retracement. Levels are derived from the two anchor prices only.
  void _fibAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH || pos.dx < 0 || pos.dx > plotW) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    final t = candles[i].time;
    setState(() {
      final p = pendingFib;
      if (p == null) {
        pendingFib = TrendLine(t, price, t, price);
      } else {
        if (t == p.t1) return; // same candle - ignore
        fibs.add(TrendLine(p.t1, p.p1, t, price));
        pendingFib = null;
        _saveFibs();
      }
    });
  }

  /// Shared y->price mapping for draw gestures.
  double? _priceAtY(double dy, Size size) {
    if (candles.isEmpty) return null;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (dy < 0 || dy > plotH) return null;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    return lo + (1 - dy / plotH) * (hi - lo);
  }

  /// Spec 9 (move): in Draw mode, dragging from an existing level moves it
  /// to follow the finger; the new price saves when the drag ends.
  void _dragLineStart(Offset pos, Size size) {
    final price = _priceAtY(pos.dy, size);
    if (price == null) return;
    double hi = -double.infinity, lo = double.infinity;
    for (final c in candles) {
      hi = hi > c.high ? hi : c.high;
      lo = lo < c.low ? lo : c.low;
    }
    final range = hi - lo;
    final hit = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    setState(() => _dragLineIdx = hit >= 0 ? hit : null);
  }

  void _dragLineUpdate(Offset pos, Size size) {
    final idx = _dragLineIdx;
    if (idx == null) return;
    final price = _priceAtY(pos.dy, size);
    if (price == null) return;
    setState(() => hLines[idx] = DrawnLine(price, hLines[idx].name));
  }

  void _dragLineEnd() {
    if (_dragLineIdx == null) return;
    setState(() => _dragLineIdx = null);
    _saveLines();
  }

  /// Draw mode: convert the tap's y position to a price and add a
  /// horizontal line; tapping near an existing line removes it.
  void _drawAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    // remove if tapping within 1% of range of an existing line
    final range = hi - lo;
    final hit = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    setState(() {
      if (hit >= 0) {
        hLines.removeAt(hit);
      } else {
        hLines.add(DrawnLine(price, 'Level ${hLines.length + 1}'));
      }
    });
    _saveLines();
  }
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final double? livePrice;
  final int? selected;
  final List<double>? sma;
  final int smaPeriod;
  final List<double>? sma200;
  final List<double>? ema;
  final int emaPeriod;
  final List<double>? rsi;
  final int rsiPeriod;
  final List<double>? macdLine;
  final List<double>? macdSignal;
  final List<double>? macdHist;
  final List<DrawnLine> hLines;
  final List<TrendLine> trendLines;
  final TrendLine? pendingTrend;
  final List<TrendLine> fibs;
  final TrendLine? pendingFib;
  final Map<int, List<double>> extraEmas;
  final (List<double>, List<double>, List<double>)? bands;
  final int firstVisible;
  final int visibleCount;

  CandlePainter({
    required this.candles,
    this.firstVisible = 0,
    this.visibleCount = 0,
    this.livePrice,
    this.selected,
    this.hLines = const [],
    this.trendLines = const [],
    this.pendingTrend,
    this.fibs = const [],
    this.pendingFib,
    this.extraEmas = const {},
    this.bands,
    this.sma,
    this.smaPeriod = 20,
    this.sma200,
    this.ema,
    this.emaPeriod = 50,
    this.rsi,
    this.rsiPeriod = 14,
    this.macdLine,
    this.macdSignal,
    this.macdHist,
  });

  static const bull = Color(0xFF2EC27E);
  static const bear = Color(0xFFE0654F);
  static const grid = Color(0xFF1C2230);
  static const axis = Color(0xFF8A93A6);
  static const gold = Color(0xFFF5C242);

  @override
  void paint(Canvas canvas, Size size) {
    const rightPad = 52.0;
    const bottomPad = 16.0;
    final rsiH = (rsi != null && rsi!.isNotEmpty) ? 64.0 : 0.0;
    final macdH = (macdLine != null && macdLine!.isNotEmpty) ? 64.0 : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (candles.isEmpty || plotW <= 0 || plotH <= 0) return;

    final n0 = candles.length;
    final vc0 = visibleCount <= 0 || visibleCount > n0 ? n0 : visibleCount;
    var fv0 = firstVisible;
    if (fv0 < 0) fv0 = 0;
    if (fv0 + vc0 > n0) fv0 = n0 - vc0 < 0 ? 0 : n0 - vc0;
    double hi = -double.infinity, lo = double.infinity;
    for (int i = fv0; i < fv0 + vc0 && i < n0; i++) {
      final c = candles[i];
      hi = math.max(hi, c.high);
      lo = math.min(lo, c.low);
    }
    if (livePrice != null) {
      hi = math.max(hi, livePrice!);
      lo = math.min(lo, livePrice!);
    }
    final pad = math.max((hi - lo) * 0.05, 0.01);
    hi += pad;
    lo -= pad;
    double y(double v) => plotH * (1 - (v - lo) / (hi - lo));

    // grid + price labels
    final gridPaint = Paint()..color = grid;
    final labelStyle = TextStyle(
      color: axis,
      fontSize: 9,
      fontFamily: 'Roboto',
      height: 1,
    );
    for (int g = 0; g <= 4; g++) {
      final v = lo + (hi - lo) * g / 4;
      final yy = y(v);
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: v.toStringAsFixed(2), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          plotW + 4,
          (yy - tp.height / 2).clamp(0.0, size.height - tp.height),
        ),
      );
    }

    // candles. The last bar is the FORMING candle: its close tracks the
    // real live quote (and its wick extends) so the chart feels live.
    // No synthetic data - livePrice is always a real feed quote.
    final eff = List<Candle>.of(candles);
    if (livePrice != null && eff.isNotEmpty) {
      final l = eff.last;
      eff[eff.length - 1] = Candle(
        time: l.time,
        open: l.open,
        high: math.max(l.high, livePrice!),
        low: math.min(l.low, livePrice!),
        close: livePrice!,
        volume: l.volume,
      );
    }
    final n = eff.length;
    final step = plotW / vc0;
    final bodyW = math.max(step * 0.65, 1.5);
    final iEnd = fv0 + vc0 < n ? fv0 + vc0 : n;
    for (int i = fv0; i < iEnd; i++) {
      final c = eff[i];
      final up = c.close >= c.open;
      final paint = Paint()..color = up ? bull : bear;
      final cx = step * (i - fv0 + 0.5);
      canvas.drawLine(
        Offset(cx, y(c.high)),
        Offset(cx, y(c.low)),
        paint..strokeWidth = 1,
      );
      final top = y(math.max(c.open, c.close));
      final bot = y(math.min(c.open, c.close));
      canvas.drawRect(
        Rect.fromLTRB(
          cx - bodyW / 2,
          top,
          cx + bodyW / 2,
          math.max(bot, top + 1),
        ),
        paint,
      );
    }

    // indicator overlays (aligned: value[i] pairs with candle[period-1+i])
    final stepI = plotW / vc0;
    void drawLine(List<double> series, int period, Color color) {
      if (series.isEmpty) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < series.length; i++) {
        final idx = period - 1 + i;
        if (idx >= n) break;
        final x = stepI * (idx - fv0 + 0.5);
        final yy = y(series[i]);
        if (i == 0) {
          path.moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
      }
      canvas.drawPath(path, paint);
    }

    if (sma != null) drawLine(sma!, smaPeriod, const Color(0xFF4EA1FF));
    if (sma200 != null) drawLine(sma200!, 200, const Color(0xFF6FD3E0));
    if (ema != null) drawLine(ema!, emaPeriod, const Color(0xFFFF9F43));

    const emaColors = {
      9: Color(0xFFB78CFF),
      21: Color(0xFFFFD166),
      200: Color(0xFF70D6FF),
    };
    for (final entry in extraEmas.entries)
      drawLine(entry.value, entry.key, emaColors[entry.key] ?? gold);
    if (bands != null) {
      drawLine(bands!.$1, 20, const Color(0xFF95D5B2));
      drawLine(bands!.$2, 20, const Color(0xFF52B788));
      drawLine(bands!.$3, 20, const Color(0xFF52B788));
    }

    // crosshair
    if (selected != null && selected! < n) {
      final c = candles[selected!];
      final cx = step * (selected! - fv0 + 0.5);
      final cy = y(c.close);
      final dash = Paint()
        ..color = axis.withOpacity(0.6)
        ..strokeWidth = 0.5;
      canvas.drawLine(Offset(cx, 0), Offset(cx, plotH), dash);
      canvas.drawLine(Offset(0, cy), Offset(plotW, cy), dash);
    }

    // last price line + tag
    final lp = livePrice ?? candles.last.close;
    final lpy = y(lp);
    final dashPaint = Paint()
      ..color = gold
      ..strokeWidth = 1;
    const dashW = 5.0, gapW = 4.0;
    double x = 0;
    while (x < plotW) {
      canvas.drawLine(
        Offset(x, lpy),
        Offset(math.min(x + dashW, plotW), lpy),
        dashPaint,
      );
      x += dashW + gapW;
    }
    final tagTp = TextPainter(
      text: TextSpan(
        text: lp.toStringAsFixed(2),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 9,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final tagY = (lpy - tagTp.height / 2).clamp(
      0.0,
      size.height - tagTp.height,
    );
    final rr = RRect.fromRectAndRadius(
      Rect.fromLTWH(plotW + 2, tagY - 2, tagTp.width + 8, tagTp.height + 4),
      const Radius.circular(3),
    );
    canvas.drawRRect(rr, Paint()..color = gold);
    tagTp.paint(canvas, Offset(plotW + 6, tagY));

    // user-drawn horizontal lines
    final hlPaint = Paint()
      ..color = const Color(0xFF5EE0A0)
      ..strokeWidth = 1;
    for (final l in hLines) {
      if (l.price < lo || l.price > hi) continue;
      final yy = y(l.price);
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), hlPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '${l.name} ${l.price.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Color(0xFF5EE0A0),
            fontSize: 9,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotW - tp.width - 2, yy - tp.height - 1));
    }

    // trend lines (anchored by candle time, extended to the plot edges)
    if (n >= 2 && (trendLines.isNotEmpty || pendingTrend != null)) {
      final tlPaint = Paint()
        ..color = const Color(0xFF6FD3E0)
        ..strokeWidth = 1.2;
      double idxAt(DateTime t) {
        final t0 = candles.first.time.millisecondsSinceEpoch;
        final tN = candles.last.time.millisecondsSinceEpoch;
        if (tN == t0) return 0;
        return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      }

      final stepT = plotW / vc0;
      void drawTrend(TrendLine l, bool dashed) {
        final x1 = stepT * (idxAt(l.t1) - fv0 + 0.5);
        final x2 = stepT * (idxAt(l.t2) - fv0 + 0.5);
        if ((x2 - x1).abs() < 1e-6) return;
        final y1 = y(l.p1), y2 = y(l.p2);
        final m = (y2 - y1) / (x2 - x1);
        final ya = y1 - m * x1; // y at x=0
        final yb = y1 + m * (plotW - x1); // y at x=plotW
        if (dashed) {
          double dx = 0;
          const dw = 6.0, gw = 4.0;
          final total = plotW;
          while (dx < total) {
            final xStart = dx;
            final xEnd = math.min(dx + dw, total);
            canvas.drawLine(
              Offset(xStart, ya + m * xStart),
              Offset(xEnd, ya + m * xEnd),
              tlPaint,
            );
            dx += dw + gw;
          }
        } else {
          canvas.drawLine(Offset(0, ya), Offset(plotW, yb), tlPaint);
        }
      }

      for (final l in trendLines) {
        drawTrend(l, false);
      }
      if (pendingTrend != null) {
        final p = pendingTrend!;
        final x = stepT * (idxAt(p.t1) - fv0 + 0.5);
        final py = y(p.p1);
        canvas.drawCircle(Offset(x, py), 3, tlPaint);
      }
    }

    // fibonacci retracements: horizontal levels between the two anchors,
    // extended right from the leftmost anchor
    if (n >= 2 && (fibs.isNotEmpty || pendingFib != null)) {
      const fibFs = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];
      final fibPaint = Paint()
        ..color = const Color(0xCCFFD166)
        ..strokeWidth = 1;
      double idxAtF(DateTime t) {
        final t0 = candles.first.time.millisecondsSinceEpoch;
        final tN = candles.last.time.millisecondsSinceEpoch;
        if (tN == t0) return 0;
        return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      }

      final stepF = plotW / vc0;
      for (final f in fibs) {
        final xStart =
            stepF * (math.min(idxAtF(f.t1), idxAtF(f.t2)) - fv0 + 0.5);
        for (final frac in fibFs) {
          final price = f.p2 + (f.p1 - f.p2) * frac;
          if (price < lo || price > hi) continue;
          final yy = y(price);
          canvas.drawLine(Offset(xStart, yy), Offset(plotW, yy), fibPaint);
          final pct = (frac * 100);
          final label =
              '${pct == pct.roundToDouble() ? pct.toInt() : pct.toStringAsFixed(1)}% ${price.toStringAsFixed(2)}';
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                color: Color(0xCCFFD166),
                fontSize: 8,
                fontFamily: 'Roboto',
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(plotW - tp.width - 2, yy - tp.height - 1));
        }
      }
      if (pendingFib != null) {
        final p = pendingFib!;
        final x = stepF * (idxAtF(p.t1) - fv0 + 0.5);
        canvas.drawCircle(Offset(x, y(p.p1)), 3, fibPaint);
      }
    }

    // RSI sub-pane
    if (rsiH > 0 && rsi != null) {
      final top = plotH + 8;
      final h = rsiH - 8;
      final rp = Paint()..color = grid;
      canvas.drawRect(
        Rect.fromLTWH(0, top, plotW, h),
        rp..color = const Color(0xFF141923),
      );
      double ry(double v) => top + h * (1 - v / 100);
      final band = Paint()..color = const Color(0xFF232A35);
      canvas.drawLine(Offset(0, ry(70)), Offset(plotW, ry(70)), band);
      canvas.drawLine(Offset(0, ry(30)), Offset(plotW, ry(30)), band);
      final rPaint = Paint()
        ..color = const Color(0xFFB78CFF)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < rsi!.length; i++) {
        final idx = rsiPeriod + i;
        if (idx >= n) break;
        final x = stepI * (idx - fv0 + 0.5);
        final yy = ry(rsi![i]);
        if (i == 0) {
          path.moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
      }
      canvas.drawPath(path, rPaint);
      final lbl = TextPainter(
        text: TextSpan(
          text: 'RSI ${rsi!.last.toStringAsFixed(1)}',
          style: const TextStyle(
            color: Color(0xFFB78CFF),
            fontSize: 9,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      lbl.paint(canvas, Offset(4, top + 2));
    }

    // time labels
    final tf = TextStyle(color: axis, fontSize: 9, fontFamily: 'Roboto');
    for (int t = 0; t < 4; t++) {
      final i = fv0 + ((vc0 - 1) * t / 3).round();
      final c = candles[i];
      final sameDay =
          c.time.day == candles.last.time.day &&
          c.time.month == candles.last.time.month;
      final s = sameDay
          ? '${c.time.hour.toString().padLeft(2, '0')}:${c.time.minute.toString().padLeft(2, '0')}'
          : '${c.time.month}/${c.time.day}';
      final tp = TextPainter(
        text: TextSpan(text: s, style: tf),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (step * (i - fv0 + 0.5) - tp.width / 2).clamp(
        0.0,
        plotW - tp.width,
      );
      tp.paint(canvas, Offset(tx, plotH + 3));
    }

    // MACD sub-pane (histogram + line/signal, real closes only)
    if (macdH > 0) {
      final top = plotH + 8 + rsiH;
      final h = macdH - 8;
      canvas.drawRect(
        Rect.fromLTWH(0, top, plotW, h),
        Paint()..color = const Color(0xFF141923),
      );
      double mn = 0, mx = 0;
      void ext(List<double>? s) {
        if (s == null) return;
        for (final v in s) {
          if (v < mn) mn = v;
          if (v > mx) mx = v;
        }
      }

      ext(macdLine);
      ext(macdSignal);
      ext(macdHist);
      if (mx - mn < 1e-9) mx = mn + 1;
      double my(double v) => top + h * (1 - (v - mn) / (mx - mn));
      canvas.drawLine(
        Offset(0, my(0)),
        Offset(plotW, my(0)),
        Paint()..color = const Color(0xFF232A35),
      );
      final stepI = plotW / vc0;
      if (macdHist != null) {
        for (int i = 0; i < macdHist!.length; i++) {
          final idx = 33 + i;
          if (idx >= n) break;
          final x = stepI * (idx - fv0 + 0.5);
          final v = macdHist![i];
          final y0 = my(0), y1 = my(v);
          canvas.drawRect(
            Rect.fromLTRB(
              x - 1.5,
              y0 < y1 ? y0 : y1,
              x + 1.5,
              y0 > y1 ? y0 : y1,
            ),
            Paint()..color = v >= 0 ? bull : bear,
          );
        }
      }
      void mline(List<double> s, int off, Color c) {
        final paint = Paint()
          ..color = c
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke;
        final path = Path();
        for (int i = 0; i < s.length; i++) {
          final idx = off + i;
          if (idx >= n) break;
          final x = stepI * (idx - fv0 + 0.5);
          if (i == 0) {
            path.moveTo(x, my(s[i]));
          } else {
            path.lineTo(x, my(s[i]));
          }
        }
        canvas.drawPath(path, paint);
      }

      mline(macdLine!, 25, const Color(0xFF4EA1FF));
      if (macdSignal != null && macdSignal!.isNotEmpty) {
        mline(macdSignal!, 33, const Color(0xFFFF9F43));
      }
      final label = TextPainter(
        text: TextSpan(
          text: 'MACD ${macdLine!.last.toStringAsFixed(2)}',
          style: const TextStyle(
            color: axis,
            fontSize: 9,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(4, top + 2));
    }
  }

  @override
  bool shouldRepaint(CandlePainter old) =>
      old.candles != candles ||
      old.livePrice != livePrice ||
      old.selected != selected ||
      old.extraEmas != extraEmas ||
      old.bands != bands ||
      old.sma != sma ||
      old.ema != ema ||
      old.rsi != rsi ||
      old.hLines != hLines ||
      old.fibs != fibs ||
      old.pendingFib != pendingFib ||
      old.trendLines != trendLines ||
      old.pendingTrend != pendingTrend;
}

/// Fullscreen chart (user request): same real candle source and live
/// price, landscape while open, orientation restored on close.
class FullscreenChartPage extends StatefulWidget {
  final CandleLoader? loader;
  final double? livePrice;
  final bool rangeMode;
  const FullscreenChartPage({
    super.key,
    this.loader,
    this.livePrice,
    this.rangeMode = false,
  });

  @override
  State<FullscreenChartPage> createState() => _FullscreenChartPageState();
}

class _FullscreenChartPageState extends State<FullscreenChartPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CandleChartPanel(
                  loader: widget.loader,
                  livePrice: widget.livePrice,
                  expand: true,
                  rangeMode: widget.rangeMode,
                ),
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: InkWell(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232A35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.fullscreen_exit,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

(String, int) tradeRangeSpec(String code) => switch (code) {
  'range:1H' => ('1min', 120),
  'range:1D' => ('15min', 120),
  'range:1W' => ('1h', 200),
  'range:1M' => ('4h', 200),
  'range:3M' => ('1day', 120),
  'range:1Y' => ('1day', 400),
  _ => (code, 120),
};
Duration tradeRangeDuration(String code) => switch (code) {
  'range:1H' => const Duration(hours: 1),
  'range:1D' => const Duration(days: 1),
  'range:1W' => const Duration(days: 7),
  'range:1M' => const Duration(days: 30),
  'range:3M' => const Duration(days: 90),
  'range:1Y' => const Duration(days: 365),
  _ => const Duration(days: 1),
};
List<Candle> trimTradeRange(List<Candle> data, String code) {
  if (data.isEmpty) return data;
  final from = data.last.time.subtract(tradeRangeDuration(code));
  return data.where((c) => !c.time.isBefore(from)).toList();
}
