import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('watch notification uses Sona and retains update-safe identifiers', () {
    final source = File(
      'android/app/src/main/kotlin/com/ambi/gold_paper_trading/OroWatchService.kt',
    ).readAsStringSync();
    expect(source, contains('"Sona is watching"'));
    expect(source, contains('"Sona watch"'));
    expect(source, contains('Shows while Sona is watching'));
    expect(source, isNot(contains('"Oro is watching"')));
    expect(source, contains('"oro_watch"'));
    expect(source, contains('NOTIF_ID = 42'));
  });
}
