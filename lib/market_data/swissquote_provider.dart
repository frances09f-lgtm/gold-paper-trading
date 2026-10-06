import 'dart:convert';
import 'package:http/http.dart' as http;
import 'market_data_provider.dart';
import 'models.dart';

/// Swissquote public best-bid/offer feed. Genuinely free, no API key,
/// real bid/ask with exchange-side timestamps.
/// https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/{base}/{quote}
class SwissquoteQuoteProvider implements MarketDataProvider {
  final http.Client client;
  static const _base =
      'https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/';

  SwissquoteQuoteProvider({http.Client? client})
      : client = client ?? http.Client();

  @override
  String get name => 'swissquote';

  @override
  List<Instrument> get instruments => Instrument.supported;

  @override
  Future<Quote> fetchQuote(Instrument instrument) async {
    final uri = Uri.parse('$_base${instrument.providerPath}');
    final res = await client.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw MarketDataException('HTTP ${res.statusCode} from $name');
    }
    final body = jsonDecode(res.body);
    if (body is! List || body.isEmpty) {
      throw MarketDataException('empty quote list from $name');
    }
    // Take the freshest platform entry.
    Map<String, dynamic>? best;
    for (final entry in body) {
      if (entry is! Map<String, dynamic>) continue;
      final eTs = (entry['ts'] as num?) ?? 0;
      final bTs = best == null ? -1 : ((best['ts'] as num?) ?? 0);
      if (eTs > bTs) best = entry;
    }
    final profiles = best?['spreadProfilePrices'];
    if (profiles is! List || profiles.isEmpty) {
      throw MarketDataException('no spread profiles from $name');
    }
    final p = profiles.first;
    final bid = (p['bid'] as num?)?.toDouble();
    final ask = (p['ask'] as num?)?.toDouble();
    final ts = (best!['ts'] as num?)?.toInt();
    if (bid == null || ask == null || ts == null || bid <= 0 || ask <= 0) {
      throw MarketDataException('malformed quote from $name');
    }
    return Quote(
      instrument: instrument.symbol,
      bid: bid,
      ask: ask,
      ts: DateTime.fromMillisecondsSinceEpoch(ts),
      source: name,
    );
  }
}

class MarketDataException implements Exception {
  final String message;
  MarketDataException(this.message);
  @override
  String toString() => 'MarketDataException: $message';
}
