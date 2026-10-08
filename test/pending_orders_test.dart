import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gold_paper_trading/pending_orders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<PendingPaperOrders> create() async {
    SharedPreferences.setMockInitialValues({});
    return PendingPaperOrders.load(await SharedPreferences.getInstance());
  }

  PendingPaperOrder order({bool above = false, bool gtc = true}) =>
      PendingPaperOrder(
        id: '1',
        side: 'buy',
        qty: .1,
        trigger: 4000,
        above: above,
        gtc: gtc,
        createdAt: 1,
        expiresAt: 100,
      );
  test(
    'threshold uses executable side, freshness and foreground, fills once',
    () async {
      final s = await create();
      s.orders.add(order());
      int calls = 0;
      Future<String?> submit(PendingPaperOrder o) async {
        calls++;
        return null;
      }

      await s.evaluate(
        bid: 3990,
        ask: 4001,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: false,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: false,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 1);
      expect(s.orders.first.status, 'filled');
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 1);
    },
  );
  test('timeout and crash stay needs review, never retry', () async {
    final s = await create();
    s.orders.add(order());
    int calls = 0;
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 50,
      submit: (o) async {
        calls++;
        throw Exception('timeout');
      },
    );
    expect(s.orders.first.status, 'needsReview');
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 50,
      submit: (o) async {
        calls++;
        return null;
      },
    );
    expect(calls, 1);
    s.orders.first.status = 'submitting';
    await s.save();
    expect(PendingPaperOrders.load(s.prefs).orders.first.status, 'needsReview');
  });
  test('expiry and cancel cannot fill', () async {
    final s = await create();
    s.orders.add(order(gtc: false));
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 100,
      submit: (o) async => throw Exception('must not submit'),
    );
    expect(s.orders.first.status, 'expired');
    s.orders.clear();
    s.orders.add(order());
    await s.cancel('1');
    expect(s.orders.first.status, 'cancelled');
  });
}
