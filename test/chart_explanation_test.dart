import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gold_paper_trading/chart_explanation.dart';
import 'package:gold_paper_trading/market_data/models.dart';
import 'package:gold_paper_trading/user_api_keys.dart';

void main() {
  Map<String, dynamic> data() => ChartExplanation.snapshot(
    candles: [
      Candle(
        time: DateTime(2026, 10, 8),
        open: 4100,
        high: 4120,
        low: 4099,
        close: 4110,
      ),
    ],
    interval: 'range:1D',
    loadedAt: 1,
    quoteAt: 1,
    bid: 4100,
    ask: 4101,
    positions: [
      {
        'status': 'open',
        'direction': 'buy',
        'entry': 4090,
        'qty': 1,
        'tp': 4120,
        'sl': 4080,
        'id': 'secret',
        'pin': 'secret',
      },
    ],
    accountAt: 0,
    now: DateTime(2026, 10, 8),
  );
  test('snapshot excludes secrets and reports stale data', () {
    final d = data();
    expect(d['quote_stale'], true);
    expect(d['account_at_ms'], null);
    expect(jsonEncode(d), isNot(contains('secret')));
    expect((d['candles'] as List).length, 1);
  });
  test('missing candles never invent chart', () {
    expect(
      () => ChartExplanation.snapshot(
        candles: [],
        interval: 'x',
        loadedAt: 0,
        quoteAt: 0,
        bid: null,
        ask: null,
        positions: [],
        accountAt: 0,
      ),
      throwsStateError,
    );
  });
  test('readonly provider sends exactly snapshot and has no trade tools', () async {
    UserApiKeys.groq = 'fixture';
    final c = MockClient((req) async {
      final j = jsonDecode(req.body);
      expect(j.containsKey('tools'), false);
      expect(j['messages'][1]['content'], jsonEncode(data()));
      expect(j['messages'][0]['content'], contains('never place trades'));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    'Saved candles rose. Quote is stale. Not financial advice.',
              },
            },
          ],
        }),
        200,
      );
    });
    expect(
      await ChartExplanation.explain(data(), client: c),
      contains('stale'),
    );
    UserApiKeys.groq = '';
  });
}
