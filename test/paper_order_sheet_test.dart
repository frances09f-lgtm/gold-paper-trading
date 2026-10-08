import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/main.dart';

class FakeAccount extends AppState {
  int calls = 0;
  String? side;
  double? qty, take, stop;
  @override
  bool get priceFresh => true;
  @override
  Future<String?> openPaper(String d, double q, double? tp, double? sl) async {
    calls++;
    side = d;
    qty = q;
    take = tp;
    stop = sl;
    return null;
  }
}

void main() {
  testWidgets(
    'sheet trades only on submit with user quantity and optional protection',
    (t) async {
      final app = FakeAccount()
        ..bid = 4000
        ..ask = 4001
        ..price = 4000.5
        ..priceOk = true
        ..priceAt = DateTime.now().millisecondsSinceEpoch;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaperOrderSheet(app: app, side: 'sell'),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(app.calls, 0);
      await t.enterText(find.byType(TextField).first, '0.25');
      await t.tap(find.byType(Switch).last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), '3990');
      await t.enterText(find.byType(TextField).at(2), '4010');
      await t.ensureVisible(find.text('Place Order at 4000.00'));
    await t.tap(find.text('Place Order at 4000.00'));
      await t.pumpAndSettle();
      expect(app.calls, 1);
      expect(app.side, 'sell');
      expect(app.qty, .25);
      expect(app.take, 3990);
      expect(app.stop, 4010);
    },
  );
}
