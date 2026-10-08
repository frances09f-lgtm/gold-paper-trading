import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gold_paper_trading/main.dart';

import 'screens_test.dart' show loadFonts;

void main() {
  testWidgets('settings exposes same API keys screen', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
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
