import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/paper_margin.dart';
import 'package:gold_paper_trading/main.dart';

class MarginAccount extends AppState {
  int opens = 0;
  bool failRefresh = false;
  MarginAccount() {
    unlocked = true;
    balance = 12;
    bid = 4119.7;
    ask = 4120.3;
    price = 4120;
    priceAt = DateTime.now().millisecondsSinceEpoch;
    priceOk = true;
  }
  @override
  Future<void> paperRefresh() async {
    if (!failRefresh) accountRevision++;
  }

  @override
  Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    if (fn == 'paper_open') opens++;
    return {};
  }
}

void main() {
  test('1oz fits12 at assumed500 but over-size does not', () {
    final f = PaperMargin.estimate(
      balance: 12,
      bid: 4120,
      ask: 4120,
      positions: [],
    );
    expect(PaperMargin.guard(free: f, price: 4120, qty: 1), null);
    expect(
      PaperMargin.guard(free: f, price: 4120, qty: 2),
      contains('insufficient'),
    );
  });
  test('all open positions and live spread reduce availability', () {
    final f = PaperMargin.estimate(
      balance: 12,
      bid: 4120,
      ask: 4121,
      positions: [
        {'status': 'open', 'direction': 'buy', 'qty': 1, 'entry': 4121},
        {'status': 'closed', 'qty': 999},
      ],
    );
    expect(f, closeTo(2.758, 1e-6));
    expect(
      PaperMargin.guard(free: f, price: 4121, qty: 1),
      contains('insufficient'),
    );
  });
  test('malformed position refuses estimate', () {
    expect(
      PaperMargin.estimate(
        balance: 12,
        bid: 4120,
        ask: 4121,
        positions: [
          {'status': 'open', 'qty': 1},
        ],
      ),
      null,
    );
  });
  test('open gate refreshes and blocks oversize before server', () async {
    final a = MarginAccount();
    expect(await a.openPaper('buy', 2, null, null), contains('insufficient'));
    expect(a.opens, 0);
    expect(await a.openPaper('buy', 1, null, null), null);
    expect(a.opens, 1);
    expect(a.openingPaper, false);
  });
  test('failed refresh cannot rely on cached balance', () async {
    final a = MarginAccount()..failRefresh = true;
    expect(
      await a.openPaper('buy', 1, null, null),
      contains('Could not refresh'),
    );
    expect(a.opens, 0);
  });
  test('pending fills use same guarded open path', () async {
    final a = MarginAccount()
      ..positions = [
        {'status': 'open', 'direction': 'sell', 'qty': 1, 'entry': 4119.7},
      ];
    expect(await a.openPaper('buy', 1, null, null), contains('insufficient'));
    expect(a.opens, 0);
  });
}
