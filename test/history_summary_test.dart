import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/main.dart';
import 'package:gold_paper_trading/history_summary.dart';

import 'screens_test.dart' show loadFonts;

void main() {
  test('summary sums actual displayed pnl and marks missing', () {
    final s = HistorySummary.from([
      {'pnl': 1.91},
      {'pnl': 1.85},
      {'pnl': 2.85},
      {'pnl': null},
      {'pnl': double.nan},
    ]);
    expect(s.total, closeTo(6.61, 1e-9));
    expect(s.known, 3);
    expect(s.missing, 2);
  });
  test('negative and zero totals are not balance', () {
    expect(
      HistorySummary.from([
        {'pnl': -3.0},
        {'pnl': 1.0},
      ]).total,
      -2,
    );
    expect(HistorySummary.from([]).total, 0);
  });
  testWidgets('history summary and cards preserve filtered scope and details', (
    t,
  ) async {
    await loadFonts();
    final app = AppState()..unlocked = true;
    app.positions = [
      for (final e in [(1, 1.91), (2, 1.85), (3, 2.85), (4, -1.0)])
        {
          'id': '${e.$1}',
          'status': 'closed',
          'direction': e.$1 == 4 ? 'buy' : 'sell',
          'qty': 1.0,
          'entry': 4100.0,
          'exit': 4098.0,
          'pnl': e.$2,
          'closed_at': '2026-10-08T10:00:00Z',
        },
    ];
    await t.binding.setSurfaceSize(const Size(412, 915));
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(
            appBar: AppBar(title: const Text('Trades')),
            body: PositionsTab(app: app),
          ),
        ),
      ),
    );
    await t.pump();
    await t.tap(find.text('History'));
    await t.pump();
    expect(find.text('Realized P/L · USD'), findsOneWidget);
    expect(find.text('+\$5.61'), findsOneWidget);
    expect(find.text('GOLD'), findsNWidgets(4));
    expect(find.text('1.00 Troy Ounce(s)'), findsNWidgets(4));
    expect(find.text('-\$1.00'), findsOneWidget);
    await t.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final b = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-history.png').writeAsBytes(b!.buffer.asUint8List());
    });
    await t.tap(find.text('GOLD').first);
    await t.pump();
    expect(find.textContaining('Entry 4100.00'), findsOneWidget);
    await t.tap(find.byType(DropdownButtonFormField<String>).at(1));
    await t.pumpAndSettle();
    await t.tap(find.text('Winning').last);
    await t.pumpAndSettle();
    expect(find.text('+\$6.61'), findsOneWidget);
    expect(find.text('-\$1.00'), findsNothing);
  });
}
