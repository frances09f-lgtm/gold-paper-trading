import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gold_paper_trading/main.dart';
import 'package:gold_paper_trading/chart/candle_chart.dart';

import 'screens_test.dart' show demoState, testCandles, loadFonts;

void main() {
  testWidgets('chart Alert mode confirms editable price; cancel never saves', (
    t,
  ) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({});
    final app = demoState();
    app.prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(
            body: TradeTab(app: app, candleLoaderOverride: testCandles),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Alert').first);
    await t.pumpAndSettle();
    final chart = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is CandlePainter,
    );
    await t.tapAt(t.getCenter(chart));
    await t.pumpAndSettle();
    expect(find.text('Create price alert?'), findsOneWidget);
    expect(app.alerts, isEmpty);
    await t.runAsync(() async {
      final im =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-chart-alert.png')
          .writeAsBytes(b!.buffer.asUint8List());
    });
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(app.alerts, isEmpty);
    await t.tapAt(t.getCenter(chart));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, '4126');
    await t.tap(find.text('Save alert'));
    await t.pumpAndSettle();
    expect(app.alerts.length, 1);
    expect(app.alerts.single.level, 4126);
    expect(app.positions.length, 4);
    expect(app.prefs!.getString('tj_price_alerts'), contains('4126'));
  });
}
