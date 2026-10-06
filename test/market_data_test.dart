import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gold_paper_trading/market_data/models.dart';
import 'package:gold_paper_trading/market_data/swissquote_provider.dart';
import 'package:gold_paper_trading/market_data/twelve_data_candles.dart';
import 'package:gold_paper_trading/market_data/realtime_price_stream.dart';

const swissquoteFixture = '''
[{"topo":{"platform":"SwissquoteCapitalMarkets","server":"Live7"},
  "spreadProfilePrices":[
    {"spreadProfile":"premium","bidSpread":25.40,"askSpread":25.40,"bid":4160.696,"ask":4161.354},
    {"spreadProfile":"prime","bidSpread":24.40,"askSpread":24.40,"bid":4160.706,"ask":4161.344}],
  "ts":1791304088743},
 {"topo":{"platform":"AT","server":"AT"},
  "spreadProfilePrices":[
    {"spreadProfile":"standard","bidSpread":27.00,"askSpread":27.00,"bid":4160.500,"ask":4161.400}],
  "ts":1791304088000}]''';

const twelveDataFixture = '''
{"meta":{"symbol":"XAU/USD","interval":"15min","currency_base":"Gold Spot"},
 "values":[
  {"datetime":"2026-10-06 14:30:00","open":"4161.10","high":"4162.40","low":"4160.80","close":"4162.10"},
  {"datetime":"2026-10-06 14:15:00","open":"4160.20","high":"4161.30","low":"4159.90","close":"4161.00"}],
 "status":"ok"}''';

http.Client fakeClient(int statusCode, String body) => MockClient((req) async {
      return http.Response(body, statusCode,
          headers: {'content-type': 'application/json'});
    });

void main() {
  group('SwissquoteQuoteProvider', () {
    test('parses real bid/ask from the freshest platform entry', () async {
      final p = SwissquoteQuoteProvider(
          client: fakeClient(200, swissquoteFixture));
      final q = await p.fetchQuote(Instrument.xauUsd);
      expect(q.instrument, 'XAU/USD');
      expect(q.bid, 4160.696);
      expect(q.ask, 4161.354);
      expect(q.spread, closeTo(0.658, 0.001));
      expect(q.mid, closeTo(4161.025, 0.001));
      expect(q.ts.millisecondsSinceEpoch, 1791304088743);
      expect(q.source, 'swissquote');
    });

    test('throws on HTTP error - no fabricated price', () {
      final p = SwissquoteQuoteProvider(client: fakeClient(500, '{}'));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('throws on empty payload', () {
      final p = SwissquoteQuoteProvider(client: fakeClient(200, '[]'));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('throws on malformed quote (zero prices)', () {
      const bad =
          '[{"spreadProfilePrices":[{"bid":0,"ask":0}],"ts":1791304088743}]';
      final p = SwissquoteQuoteProvider(client: fakeClient(200, bad));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });
  });

  group('TwelveDataCandleService', () {
    test('parses OHLC candles oldest-first', () async {
      final s = TwelveDataCandleService(
          apiKey: 'testkey', client: fakeClient(200, twelveDataFixture));
      final candles =
          await s.fetchCandles(Instrument.xauUsd, interval: '15min');
      expect(candles.length, 2);
      expect(candles.first.time, DateTime.parse('2026-10-06 14:15:00'));
      expect(candles.first.close, 4161.00);
      expect(candles.last.close, 4162.10);
    });

    test('refuses to call without an API key', () {
      final s = TwelveDataCandleService(apiKey: '', client: fakeClient(200, '{}'));
      expect(() => s.fetchCandles(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('surfaces provider error responses', () {
      final s = TwelveDataCandleService(
          apiKey: 'k',
          client: fakeClient(
              200, '{"status":"error","message":"invalid symbol"}'));
      expect(() => s.fetchCandles(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });
  });

  group('RealtimePriceStream', () {
    test('connected -> keeps last real quote on error -> disconnects after maxFailures, never fabricates', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(swissquoteFixture, 200);
        }
        return http.Response('boom', 500);
      });
      final rps = RealtimePriceStream(
        provider: SwissquoteQuoteProvider(client: client),
        interval: const Duration(milliseconds: 20),
        maxFailures: 3,
      );
      final events = <QuoteEvent>[];
      final sub = rps.stream.listen(events.add);
      rps.start();
      await Future.delayed(const Duration(milliseconds: 250));
      await sub.cancel();
      await rps.stop();

      expect(events.first.status, MarketDataStatus.connected);
      expect(events.first.quote!.bid, 4160.696);
      // failures: reconnecting twice, then disconnected
      expect(events[1].status, MarketDataStatus.reconnecting);
      expect(events[2].status, MarketDataStatus.reconnecting);
      expect(events[3].status, MarketDataStatus.disconnected);
      // last real quote is retained, never replaced
      expect(events[3].quote!.bid, 4160.696);
    });
  });

  group('Quote model', () {
    test('spread/mid/staleness', () {
      final q = Quote(
        instrument: 'XAU/USD',
        bid: 100,
        ask: 101,
        ts: DateTime.now(),
        source: 'test',
      );
      expect(q.spread, closeTo(1, 1e-9));
      expect(q.mid, closeTo(100.5, 1e-9));
      expect(q.isStale(const Duration(minutes: 1)), isFalse);
      final old = Quote(
        instrument: 'XAU/USD',
        bid: 100,
        ask: 101,
        ts: DateTime.now().subtract(const Duration(minutes: 10)),
        source: 'test',
      );
      expect(old.isStale(const Duration(minutes: 1)), isTrue);
    });
  });
}
