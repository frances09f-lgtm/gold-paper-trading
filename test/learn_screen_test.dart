import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/learn_screen.dart';
import 'package:gold_paper_trading/main.dart';

import 'screens_test.dart' show loadFonts;

void main() {
  testWidgets('lessons expose app math without broker claims', (t) async {
    await loadFonts();
    await t.binding.setSurfaceSize(const Size(412, 1100));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final k = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: k,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: const LearnScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Oz is size, not profit'), findsOneWidget);
    await t.tap(find.text('Oz is size, not profit'));
    await t.pumpAndSettle();
    expect(find.textContaining('0.01 oz it is \$0.03'), findsOneWidget);
    await t.runAsync(() async {
      final im =
          await (k.currentContext!.findRenderObject() as RenderRepaintBoundary)
              .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-learn.png').writeAsBytes(b!.buffer.asUint8List());
    });
    expect(
      LearnScreen.lessons.map((x) => x.$2).join(' '),
      contains('not server or broker accounting'),
    );
    expect(
      LearnScreen.lessons.map((x) => x.$2).join(' '),
      contains('no liquidation model'),
    );
  });
}
