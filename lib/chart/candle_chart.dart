import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
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

class CandleChartPanel extends StatefulWidget {
  /// Loads real candles; may throw. When null, no candle source is
  /// configured and the panel says so instead of drawing fake bars.
  final CandleLoader? loader;

  /// Latest live price for the dashed last-price line (optional).
  final double? livePrice;

  const CandleChartPanel({super.key, this.loader, this.livePrice});

  @override
  State<CandleChartPanel> createState() => CandleChartPanelState();
}

class CandleChartPanelState extends State<CandleChartPanel> {
  ChartInterval interval = intervals[1]; // 15m default
  List<Candle> candles = [];
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
  bool drawMode = false;
  final List<DrawnLine> hLines = []; // user-drawn named price levels

  @override
  void initState() {
    super.initState();
    _loadLines();
    _load();
    _armTimer();
  }

  /// Spec 9: drawn levels are stored locally (device), never on the server.
  Future<void> _loadLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_lines');
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      setState(() {
        hLines
          ..clear()
          ..addAll(list.map((e) => DrawnLine(
              (e['p'] as num).toDouble(), e['n']?.toString() ?? 'Level')));
      });
    } catch (_) {}
  }

  Future<void> _saveLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'tj_draw_lines',
          jsonEncode(hLines
              .map((e) => {'p': e.price, 'n': e.name})
              .toList()));
    } catch (_) {}
  }

  /// Long-press near a drawn line: rename it (Support, Resistance, ...) or
  /// delete it (spec 9: create / edit / delete / rename).
  Future<void> _editLineAt(Offset pos, Size size) async {
    if (hLines.isEmpty || candles.isEmpty) return;
    const rightPad = 52.0;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    double hi = -double.infinity, lo = double.infinity;
    for (final c in candles) {
      hi = hi > c.high ? hi : c.high;
      lo = lo < c.low ? lo : c.low;
    }
    if (widget.livePrice != null) {
      hi = hi > widget.livePrice! ? hi : widget.livePrice!;
      lo = lo < widget.livePrice! ? lo : widget.livePrice!;
    }
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final range = hi - lo;
    final idx = hLines.indexWhere((l) => (l.price - price).abs() < range * 0.02);
    if (idx < 0) return;
    final line = hLines[idx];
    final ctrl = TextEditingController(text: line.name);
    final act = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF161B24),
        title: Text('Level at ${line.price.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Name (e.g. Support, Resistance)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, 'delete'),
              child: const Text('Delete',
                  style: TextStyle(color: Color(0xFFFF6B6B)))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dCtx, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    setState(() {
      if (act == 'delete') {
        hLines.removeAt(idx);
      } else if (act == 'save') {
        hLines[idx] =
            DrawnLine(line.price, ctrl.text.trim().isEmpty ? 'Level' : ctrl.text.trim());
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
    try {
      final data = await loader(interval.code);
      if (!mounted) return;
      setState(() {
        candles = data;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
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
          Row(children: [
            const Text('XAU/USD',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            _indChip('SMA', smaOn, const Color(0xFF4EA1FF),
                () => setState(() => smaOn = !smaOn)),
            _indChip('EMA', emaOn, const Color(0xFFFF9F43),
                () => setState(() => emaOn = !emaOn)),
            _indChip('200', sma200On, const Color(0xFF6FD3E0),
                () => setState(() => sma200On = !sma200On)),
            _indChip('RSI', rsiOn, const Color(0xFFB78CFF),
                () => setState(() => rsiOn = !rsiOn)),
            _indChip('MACD', macdOn, const Color(0xFFF27EA9),
                () => setState(() => macdOn = !macdOn)),
            _indChip('Draw', drawMode, const Color(0xFF5EE0A0),
                () => setState(() => drawMode = !drawMode)),
            if (loading)
              const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFFF5C242))),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            ...intervals.map((iv) {
              final on = iv.code == interval.code;
              return GestureDetector(
                onTap: () => _setInterval(iv),
                child: Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: on ? const Color(0xFFF5C242) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: on
                            ? const Color(0xFFF5C242)
                            : const Color(0xFF2A3140)),
                  ),
                  child: Text(iv.label,
                      style: TextStyle(
                          color: on ? Colors.black : const Color(0xFF8A93A6),
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              );
            }),
          ]),
          const SizedBox(height: 6),
          _legend(dim),
          const SizedBox(height: 4),
          SizedBox(
              height: 220 +
                  ((rsiOn && candles.length > 14) ? 60 : 0) +
                  ((macdOn && candles.length > 33) ? 60 : 0),
              child: _body()),
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
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 6),
        Row(children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          const Text('Trend bias: ',
              style: TextStyle(color: dim, fontSize: 11)),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          const Spacer(),
          Icon(biasExpanded ? Icons.expand_less : Icons.expand_more,
              size: 16, color: dim),
        ]),
        if (biasExpanded) ...[
          const SizedBox(height: 4),
          for (final f in r.factors)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.score > 0 ? '+' : (f.score < 0 ? '-' : '·'),
                        style: TextStyle(
                            color: f.score > 0
                                ? green
                                : (f.score < 0 ? red : dim),
                            fontSize: 11)),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(f.text,
                            style: const TextStyle(
                                color: Color(0xFFB9C0CE), fontSize: 11))),
                  ]),
            ),
          const SizedBox(height: 4),
          const Text('Rule-based read of the current chart. Not a prediction.',
              style: TextStyle(
                  color: dim, fontSize: 10, fontStyle: FontStyle.italic)),
        ],
      ]),
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
          child: Text(label,
              style: TextStyle(
                  color: on ? color : const Color(0xFF8A93A6),
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
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
      return Text(error!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFE0654F), fontSize: 11));
    }
    if (c == null) {
      return Text(
          widget.loader == null
              ? 'Candle feed not configured (set MARKET_DATA_API_KEY)'
              : 'Loading real candles...',
          style: TextStyle(color: dim, fontSize: 11));
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
          child: Text('No candle source configured.\nReal data only - no demo bars.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12)));
    }
    if (candles.isEmpty && loading) {
      return const Center(
          child: Text('Fetching candles from Twelve Data...',
              style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12)));
    }
    if (candles.isEmpty) {
      // The legend above the chart already shows the error detail.
      return const Center(
          child: Text('No candles returned',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Color(0xFF8A93A6), fontSize: 12)));
    }
    return LayoutBuilder(builder: (context, cons) {
      return GestureDetector(
        onPanDown: (d) {
          if (!drawMode) _pick(d.localPosition, cons.maxWidth);
        },
        onPanUpdate: (d) {
          if (!drawMode) _pick(d.localPosition, cons.maxWidth);
        },
        onPanEnd: (_) {
          if (!drawMode) setState(() => selected = null);
        },
        onTapDown: (d) {
          if (drawMode) {
            _drawAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
          } else {
            _pick(d.localPosition, cons.maxWidth);
          }
        },
        onLongPressStart: (d) {
          _editLineAt(
              d.localPosition, Size(cons.maxWidth, cons.maxHeight));
        },
        child: CustomPaint(
          size: Size(cons.maxWidth, cons.maxHeight),
          painter: CandlePainter(
              candles: candles,
              livePrice: widget.livePrice,
              selected: selected,
              hLines: hLines,
              sma: smaOn ? sma(candles, 20) : null,
              sma200: sma200On ? sma(candles, 200) : null,
              smaPeriod: 20,
              ema: emaOn ? ema(candles, 50) : null,
              emaPeriod: 50,
              rsi: rsiOn ? rsi(candles, 14) : null,
              macdLine: macdOn ? macd(candles).$1 : null,
              macdSignal: macdOn ? macd(candles).$2 : null,
              macdHist: macdOn ? macd(candles).$3 : null,
              rsiPeriod: 14),
        ),
      );
    });
  }

  void _pick(Offset pos, double width) {
    const rightPad = 52.0;
    final plotW = width - rightPad;
    if (plotW <= 0 || candles.isEmpty) return;
    final n = candles.length;
    final i = ((pos.dx / plotW) * n).floor().clamp(0, n - 1);
    setState(() => selected = i);
  }

  /// Draw mode: convert the tap's y position to a price and add a
  /// horizontal line; tapping near an existing line removes it.
  void _drawAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const rightPad = 52.0;
    const bottomPad = 16.0;
    final rsiH = (rsiOn && candles.length > 14) ? 64.0 : 0.0;
    final macdH = (macdOn && candles.length > 33) ? 64.0 : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    double hi = -double.infinity, lo = double.infinity;
    for (final c in candles) {
      hi = hi > c.high ? hi : c.high;
      lo = lo < c.low ? lo : c.low;
    }
    if (widget.livePrice != null) {
      hi = hi > widget.livePrice! ? hi : widget.livePrice!;
      lo = lo < widget.livePrice! ? lo : widget.livePrice!;
    }
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    // remove if tapping within 1% of range of an existing line
    final range = hi - lo;
    final hit =
        hLines.indexWhere((l) => (l.price - price).abs() < range * 0.02);
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

  CandlePainter(
      {required this.candles,
      this.livePrice,
      this.selected,
      this.hLines = const [],
      this.sma,
      this.smaPeriod = 20,
      this.sma200,
      this.ema,
      this.emaPeriod = 50,
      this.rsi,
      this.rsiPeriod = 14,
      this.macdLine,
      this.macdSignal,
      this.macdHist});

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

    double hi = -double.infinity, lo = double.infinity;
    for (final c in candles) {
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
        color: axis, fontSize: 9, fontFamily: 'Roboto', height: 1);
    for (int g = 0; g <= 4; g++) {
      final v = lo + (hi - lo) * g / 4;
      final yy = y(v);
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), gridPaint);
      final tp = TextPainter(
          text: TextSpan(text: v.toStringAsFixed(2), style: labelStyle),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(plotW + 4, (yy - tp.height / 2).clamp(0.0, size.height - tp.height)));
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
    final step = plotW / n;
    final bodyW = math.max(step * 0.65, 1.5);
    for (int i = 0; i < n; i++) {
      final c = eff[i];
      final up = c.close >= c.open;
      final paint = Paint()..color = up ? bull : bear;
      final cx = step * (i + 0.5);
      canvas.drawLine(Offset(cx, y(c.high)), Offset(cx, y(c.low)), paint..strokeWidth = 1);
      final top = y(math.max(c.open, c.close));
      final bot = y(math.min(c.open, c.close));
      canvas.drawRect(
          Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, math.max(bot, top + 1)),
          paint);
    }

    // indicator overlays (aligned: value[i] pairs with candle[period-1+i])
    final stepI = plotW / n;
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
        final x = stepI * (idx + 0.5);
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

    // crosshair
    if (selected != null && selected! < n) {
      final c = candles[selected!];
      final cx = step * (selected! + 0.5);
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
      canvas.drawLine(Offset(x, lpy), Offset(math.min(x + dashW, plotW), lpy), dashPaint);
      x += dashW + gapW;
    }
    final tagTp = TextPainter(
        text: TextSpan(
            text: lp.toStringAsFixed(2),
            style: const TextStyle(
                color: Colors.black,
                fontSize: 9,
                fontFamily: 'Roboto',
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr)
      ..layout();
    final tagY = (lpy - tagTp.height / 2).clamp(0.0, size.height - tagTp.height);
    final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(plotW + 2, tagY - 2, tagTp.width + 8, tagTp.height + 4),
        const Radius.circular(3));
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
                  fontFamily: 'Roboto')),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas,
          Offset(plotW - tp.width - 2, yy - tp.height - 1));
    }

    // RSI sub-pane
    if (rsiH > 0 && rsi != null) {
      final top = plotH + 8;
      final h = rsiH - 8;
      final rp = Paint()..color = grid;
      canvas.drawRect(Rect.fromLTWH(0, top, plotW, h), rp..color = const Color(0xFF141923));
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
        final x = stepI * (idx + 0.5);
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
                  fontFamily: 'Roboto')),
          textDirection: TextDirection.ltr)
        ..layout();
      lbl.paint(canvas, Offset(4, top + 2));
    }

    // time labels
    final tf = TextStyle(color: axis, fontSize: 9, fontFamily: 'Roboto');
    for (int t = 0; t < 4; t++) {
      final i = ((n - 1) * t / 3).round();
      final c = candles[i];
      final sameDay = c.time.day == candles.last.time.day &&
          c.time.month == candles.last.time.month;
      final s = sameDay
          ? '${c.time.hour.toString().padLeft(2, '0')}:${c.time.minute.toString().padLeft(2, '0')}'
          : '${c.time.month}/${c.time.day}';
      final tp = TextPainter(
          text: TextSpan(text: s, style: tf), textDirection: TextDirection.ltr)
        ..layout();
      final tx = (step * (i + 0.5) - tp.width / 2).clamp(0.0, plotW - tp.width);
      tp.paint(canvas, Offset(tx, plotH + 3));
    }

    // MACD sub-pane (histogram + line/signal, real closes only)
    if (macdH > 0) {
      final top = plotH + 8 + rsiH;
      final h = macdH - 8;
      canvas.drawRect(Rect.fromLTWH(0, top, plotW, h),
          Paint()..color = const Color(0xFF141923));
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
      canvas.drawLine(Offset(0, my(0)), Offset(plotW, my(0)),
          Paint()..color = const Color(0xFF232A35));
      final stepI = plotW / n;
      if (macdHist != null) {
        for (int i = 0; i < macdHist!.length; i++) {
          final idx = 33 + i;
          if (idx >= n) break;
          final x = stepI * (idx + 0.5);
          final v = macdHist![i];
          final y0 = my(0), y1 = my(v);
          canvas.drawRect(
              Rect.fromLTRB(x - 1.5, y0 < y1 ? y0 : y1, x + 1.5,
                  y0 > y1 ? y0 : y1),
              Paint()..color = v >= 0 ? bull : bear);
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
          final x = stepI * (idx + 0.5);
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
                  color: axis, fontSize: 9, fontFamily: 'Roboto')),
          textDirection: TextDirection.ltr)
        ..layout();
      label.paint(canvas, Offset(4, top + 2));
    }
  }

  @override
  bool shouldRepaint(CandlePainter old) =>
      old.candles != candles ||
      old.livePrice != livePrice ||
      old.selected != selected ||
      old.sma != sma ||
      old.ema != ema ||
      old.rsi != rsi ||
      old.hLines != hLines;
}
