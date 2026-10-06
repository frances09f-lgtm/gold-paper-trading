import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/notification_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('entry json round-trip', () {
    final e = NotificationLogEntry(
        title: 'Take Profit', body: 'Buy XAU/USD x1.00 closed at 4154.00',
        at: DateTime(2026, 10, 7, 1, 30));
    final back = NotificationLogEntry.fromJson(e.toJson());
    expect(back.title, 'Take Profit');
    expect(back.body, contains('4154.00'));
    expect(back.at, e.at);
  });

  test('add prepends, caps at 100, unread counts after seen', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < 105; i++) {
      await NotificationLog.add('Alert $i', 'body $i');
    }
    final entries = NotificationLog.read(prefs);
    expect(entries.length, 100);
    expect(entries.first.title, 'Alert 104'); // newest first
    expect(NotificationLog.unread(prefs), 100); // never seen
    await NotificationLog.markSeen(prefs);
    expect(NotificationLog.unread(prefs), 0);
    await NotificationLog.add('New', 'b');
    expect(NotificationLog.unread(prefs), 1);
    await NotificationLog.clear(prefs);
    expect(NotificationLog.read(prefs), isEmpty);
  });
}
