/// Market data models. Real data only - a Quote is either fetched from the
/// provider or absent; nothing here fabricates prices.

enum MarketDataStatus { connected, reconnecting, disconnected }

class Instrument {
  final String symbol; // e.g. 'XAU/USD'
  final String providerPath; // provider-specific path, e.g. 'XAU/USD'
  const Instrument(this.symbol, this.providerPath);

  static const xauUsd = Instrument('XAU/USD', 'XAU/USD');
  static const supported = [
    xauUsd,
    Instrument('EUR/USD', 'EUR/USD'),
    Instrument('GBP/USD', 'GBP/USD'),
    Instrument('USD/JPY', 'USD/JPY'),
    Instrument('AUD/USD', 'AUD/USD'),
    Instrument('USD/CAD', 'USD/CAD'),
  ];
}

class Quote {
  final String instrument;
  final double bid;
  final double ask;
  final DateTime ts;
  final String source;

  const Quote({
    required this.instrument,
    required this.bid,
    required this.ask,
    required this.ts,
    required this.source,
  });

  double get spread => ask - bid;
  double get mid => (bid + ask) / 2;

  bool isStale(Duration maxAge) =>
      DateTime.now().difference(ts) > maxAge;

  Map<String, dynamic> toJson() => {
        'instrument': instrument,
        'bid': bid,
        'ask': ask,
        'spread': spread,
        'ts': ts.toIso8601String(),
        'source': source,
      };
}

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double? volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume,
  });
}

class QuoteEvent {
  final Quote? quote; // null only when never connected
  final MarketDataStatus status;
  final String? error;

  const QuoteEvent({this.quote, required this.status, this.error});
}
