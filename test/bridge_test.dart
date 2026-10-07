import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gold_paper_trading/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OroBridge snapshot (Friday offline bridge)', () {
    test('quote + paper cache merge into one real snapshot', () async {
      SharedPreferences.setMockInitialValues({
        'tj_paper_cache': jsonEncode({
          'starting': 10000.0,
          'balance': 9982.3,
          'positions': [
            {
              'direction': 'buy',
              'qty': 1.5,
              'entry': 4119.7,
              'tp': 4125.0,
              'sl': 4117.0,
              'status': 'open',
            },
            {
              'direction': 'sell',
              'qty': 1.0,
              'entry': 4000.0,
              'status': 'closed',
            },
          ],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      OroBridge.noteQuote(prefs, 4123.0, 4123.8, 123456789);

      final raw = prefs.getString(OroBridge.snapshotKey)!;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['bid'], 4123.0);
      expect(j['ask'], 4123.8);
      expect(j['quoteAt'], 123456789);
      expect(j['balance'], 9982.3);
      // closed positions are excluded
      expect((j['open'] as List).length, 1);
      expect((j['open'] as List).first['entry'], 4119.7);
      expect((j['open'] as List).first['tp'], 4125.0);
      expect(j['ts'], isNonZero);
    });

    test('a bad quote update never overwrites the last good quote', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      OroBridge.noteQuote(prefs, 5555.0, 5555.5, 777);
      OroBridge.noteQuote(prefs, 0, -5, 123); // rejected
      final j = jsonDecode(prefs.getString(OroBridge.snapshotKey)!)
          as Map<String, dynamic>;
      expect(j['bid'], 5555.0);
      expect(j['ask'], 5555.5);
      expect(j['quoteAt'], 777);
    });

    test('no paper cache: snapshot still carries the quote, no crash', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      OroBridge.noteQuote(prefs, 4000.0, 4000.5, 99);
      final j = jsonDecode(prefs.getString(OroBridge.snapshotKey)!)
          as Map<String, dynamic>;
      expect(j['balance'], isNull);
      expect((j['open'] as List), isEmpty);
      expect(j['bid'], 4000.0);
    });

    test('notePaper rewrites with fresh positions', () async {
      SharedPreferences.setMockInitialValues({
        'tj_paper_cache': jsonEncode({
          'balance': 5000.0,
          'positions': [],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      OroBridge.notePaper(prefs);
      final j = jsonDecode(prefs.getString(OroBridge.snapshotKey)!)
          as Map<String, dynamic>;
      expect(j['balance'], 5000.0);
    });
  });
}
