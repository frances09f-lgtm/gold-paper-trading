import 'dart:io';
import 'dart:ui' as ui;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gold_paper_trading/main.dart';

import 'screens_test.dart' show loadFonts, demoState, testCandles;

void main() {
  testWidgets('trade chart and pinned actions stay in one phone frame', (
    t,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Root(testApp: demoState(), candleLoaderOverride: testCandles),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(find.text('API settings'), findsNothing);
    final sell = t.getRect(find.text('SELL'));
    final buy = t.getRect(find.text('BUY'));
    expect(sell.bottom, lessThan(844));
    expect(buy.bottom, lessThan(844));
    expect(find.text('XAU/USD'), findsWidgets);
    await t.runAsync(() async {
      final im =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-one-frame.png')
          .writeAsBytes(b!.buffer.asUint8List());
    });
    await t.drag(find.byType(ListView).first, const Offset(0, -700));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(t.getRect(find.text('SELL')), sell);
    expect(t.getRect(find.text('BUY')), buy);
    expect(t.takeException(), isNull);
  });
  testWidgets('settings exposes same API keys screen', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(412, 915));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: SonaSettingsScreen(app: AppState()),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('API settings'), findsOneWidget);
    await t.runAsync(() async {
      final im =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-settings.png')
          .writeAsBytes(b!.buffer.asUint8List());
    });
    await t.tap(find.text('API settings'));
    await t.pumpAndSettle();
    expect(find.byType(ApiKeysScreen), findsOneWidget);
  });
}
