import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gold_paper_trading/chart/candle_chart.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

void main() {
  testWidgets('named presets save restore delete and reject duplicates', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = GlobalKey<CandleChartPanelState>();
    final boundary = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            body: CandleChartPanel(
              key: key,
              loader: (_) async => fakeCandles(60),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final s = key.currentState!;
    s.rsiOn = true;
    s.visibleOverride = 30;
    await s.savePreset('My layout');
    await expectLater(s.savePreset('my layout'), throwsStateError);
    s.rsiOn = false;
    s.visibleOverride = null;
    final saved = await s.readPresets();
    s.applyPreset(Map<String, dynamic>.from(saved['My layout']));
    await t.pumpAndSettle();
    expect(s.rsiOn, true);
    expect(s.visibleOverride, 30);
    await t.tap(find.byTooltip('Chart layouts'));
    await t.pumpAndSettle();
    expect(find.text('My layout'), findsOneWidget);
    await t.runAsync(() async {
      final im =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-presets.png').writeAsBytes(b!.buffer.asUint8List());
    });
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    await s.deletePreset('My layout');
    expect(await s.readPresets(), isEmpty);
  });
}
