import 'models.dart';

/// Abstraction over a market-data provider (spec section 3).
/// Implementations must return real provider data or throw - never
/// generate, interpolate, or hard-code prices.
abstract class MarketDataProvider {
  String get name;
  List<Instrument> get instruments;

  /// Latest bid/ask for [instrument]. Throws on any failure.
  Future<Quote> fetchQuote(Instrument instrument);
}

/// Historical OHLC candles (spec section 3). Separate because the free
/// quote source and the free candle source differ.
abstract class HistoricalCandleService {
  String get name;

  /// Candles oldest-first. [interval] examples: '1min', '5min', '15min',
  /// '1h', '1day' (provider-specific mapping).
  Future<List<Candle>> fetchCandles(
    Instrument instrument, {
    String interval = '15min',
    int limit = 200,
  });
}
