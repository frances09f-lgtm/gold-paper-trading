import 'dart:async';
import 'market_data_provider.dart';
import 'models.dart';

/// Polling-based realtime price stream behind the WebSocket-shaped
/// abstraction from the spec. Free XAU/USD feeds offer REST only, so this
/// polls; a WebSocket implementation can drop in behind the same API.
///
/// Emits QuoteEvent with status transitions:
///   connected     - a fresh quote arrived
///   reconnecting  - fetch failed, retrying with backoff (last quote kept)
///   disconnected  - failed repeatedly; UI must show MARKET DATA DISCONNECTED
/// No quote is ever fabricated: after disconnect the last REAL quote is
/// kept and flagged stale; nothing replaces it.
class RealtimePriceStream {
  final MarketDataProvider provider;
  final Instrument instrument;
  final Duration interval;
  final int maxFailures;

  final _controller = StreamController<QuoteEvent>.broadcast();
  Timer? _timer;
  Quote? _last;
  int _failures = 0;
  bool _running = false;

  RealtimePriceStream({
    required this.provider,
    this.instrument = Instrument.xauUsd,
    this.interval = const Duration(seconds: 5),
    this.maxFailures = 3,
  });

  Stream<QuoteEvent> get stream => _controller.stream;
  Quote? get lastQuote => _last;

  void start() {
    if (_running) return;
    _running = true;
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    try {
      final q = await provider.fetchQuote(instrument);
      _last = q;
      _failures = 0;
      _controller.add(QuoteEvent(quote: q, status: MarketDataStatus.connected));
    } catch (e) {
      _failures++;
      final status = _failures >= maxFailures
          ? MarketDataStatus.disconnected
          : MarketDataStatus.reconnecting;
      _controller.add(QuoteEvent(
          quote: _last, status: status, error: e.toString()));
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    await _controller.close();
  }
}
