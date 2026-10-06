/// Runtime config for the market-data layer. Secrets come from the build
/// environment (--dart-define), never from source control.
/// See .env.example.
class MarketDataConfig {
  /// Which quote provider to use. Only 'swissquote' is implemented now.
  static const provider =
      String.fromEnvironment('MARKET_DATA_PROVIDER', defaultValue: 'swissquote');

  /// API key for the candle service (Twelve Data free tier). Empty means
  /// candles are unavailable - the UI must say so, not fake them.
  static const apiKey = String.fromEnvironment('MARKET_DATA_API_KEY');

  /// Quote poll interval. The Swissquote feed is REST-only, so the
  /// realtime stream polls (WebSocket is not available on free feeds).
  static const pollIntervalMs =
      int.fromEnvironment('MARKET_DATA_POLL_MS', defaultValue: 5000);
}
