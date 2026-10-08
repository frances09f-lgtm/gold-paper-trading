import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/main.dart';

import 'screens_test.dart' show loadFonts;

void main() {
  test('projected result uses level not live pnl', () {
    final p = {'direction': 'buy', 'entry': 4116.68, 'qty': .01};
    expect(pnlAtLevel(p, 4119), closeTo(.0232, 1e-9));
    expect(pnlAtLevel(p, 4115), closeTo(-.0168, 1e-9));
  });
  testWidgets('TP edits update projected profit live', (t) async {
    await loadFonts();
    final app = AppState()
      ..unlocked = true
      ..price = 4114.68
      ..bid = 4114.68
      ..ask = 4114.8
      ..priceOk = true
      ..priceAt = DateTime.now().millisecondsSinceEpoch;
    app.positions = [
      {
        'id': 'p',
        'direction': 'buy',
        'entry': 4116.68,
        'qty': .01,
        'status': 'open',
        'tp': null,
        'sl': null,
      },
    ];
    app.expanded.add('p');
    await t.binding.setSurfaceSize(const Size(412, 915));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(body: PositionsTab(app: app)),
        ),
      ),
    );
    await t.pump();
    await t.ensureVisible(find.text('Take Profit'));
    await t.tap(find.text('Take Profit'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byType(TextField), '4119');
    await t.pump();
    final label = find.text('Projected P/L at Take Profit: +\$0.02');
    expect(label, findsOneWidget);
    expect((t.widget(label) as Text).style!.color, cGreen);
    await t.runAsync(() async {
      final im =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final d = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/oro-projected-pnl.png')
          .writeAsBytes(d!.buffer.asUint8List());
    });
    await t.enterText(find.byType(TextField), '4115');
    await t.pump();
    expect(find.text('Projected P/L at Take Profit: -\$0.02'), findsOneWidget);
  });
}
