import 'dart:convert';
import 'package:http/http.dart' as http;
import 'market_data_provider.dart';
import 'swissquote_provider.dart';
import 'models.dart';

/// Twelve Data time_series - real Gold Spot / US Dollar (XAU/USD) OHLC
/// candles. Free tier: 8 credits/min, 800/day. Requires an API key that
/// MUST come from config (dart-define / env), never hard-coded.
/// https://api.twelvedata.com/time_series?symbol=XAU/USD&interval=15min
class TwelveDataCandleService implements HistoricalCandleService {
  final http.Client client;
  final String apiKey;

  TwelveDataCandleService({required this.apiKey, http.Client? client})
      : client = client ?? http.Client();

  @override
  String get name => 'twelvedata';

  @override
  Future<List<Candle>> fetchCandles(
    Instrument instrument, {
    String interval = '15min',
    int limit = 200,
  }) async {
    if (apiKey.isEmpty) {
      throw MarketDataException(
          'no API key configured for $name (set MARKET_DATA_API_KEY)');
    }
    final uri = Uri.https('api.twelvedata.com', '/time_series', {
      'symbol': instrument.symbol,
      'interval': interval,
      'outputsize': '$limit',
      'apikey': apiKey,
    });
    final res = await client.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw MarketDataException('HTTP ${res.statusCode} from $name');
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      throw MarketDataException('unexpected candle payload from $name');
    }
    if (body['status'] == 'error') {
      throw MarketDataException(
          '$name error: ${body['message'] ?? 'unknown'}');
    }
    final values = body['values'];
    if (values is! List) {
      throw MarketDataException('no candle values from $name');
    }
    final out = <Candle>[];
    for (final v in values) {
      if (v is! Map<String, dynamic>) continue;
      final time = DateTime.tryParse(v['datetime']?.toString() ?? '');
      final o = double.tryParse(v['open']?.toString() ?? '');
      final h = double.tryParse(v['high']?.toString() ?? '');
      final l = double.tryParse(v['low']?.toString() ?? '');
      final c = double.tryParse(v['close']?.toString() ?? '');
      if (time == null || o == null || h == null || l == null || c == null) {
        continue;
      }
      out.add(Candle(
        time: time,
        open: o,
        high: h,
        low: l,
        close: c,
        volume: double.tryParse(v['volume']?.toString() ?? ''),
      ));
    }
    if (out.isEmpty) {
      throw MarketDataException('zero usable candles from $name');
    }
    out.sort((a, b) => a.time.compareTo(b.time)); // oldest-first
    return out;
  }
}
