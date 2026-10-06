import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/sessions.dart';

void main() {
  test('mid-London afternoon: London and New York open, APAC closed', () {
    final t = DateTime.utc(2026, 10, 7, 14, 0); // Wednesday
    final s = {for (final e in sessionsNow(t)) e.name: e.open};
    expect(s['London'], true);
    expect(s['New York'], true);
    expect(s['Tokyo'], false);
    expect(s['Sydney'], false);
  });

  test('sydney wraps midnight; weekend all closed', () {
    final t = DateTime.utc(2026, 10, 6, 22, 0); // Tuesday 22:00 UTC
    final s = {for (final e in sessionsNow(t)) e.name: e.open};
    expect(s['Sydney'], true);
    expect(s['London'], false);
    final sat = DateTime.utc(2026, 10, 10, 12, 0); // Saturday
    expect(sessionsNow(sat).every((e) => !e.open), true);
    expect(nextSession(sat), ('Sydney', 21));
  });

  test('daily settlement break 21:00-22:00 UTC on weekdays', () {
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 7, 21, 18)), true);
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 7, 20, 59)), false);
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 7, 22, 0)), false);
    final msg = marketClosedMessage(DateTime.utc(2026, 10, 7, 21, 30));
    expect(msg, contains('daily 1-hour break'));
    expect(marketClosedMessage(DateTime.utc(2026, 10, 7, 12, 0)), isNull);
  });

  test('weekend close Friday 21:00 UTC to Sunday 21:00 UTC', () {
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 9, 21, 0)), true); // Fri
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 10, 12, 0)), true); // Sat
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 11, 20, 0)), true); // Sun
    expect(metalsMarketClosed(DateTime.utc(2026, 10, 11, 21, 0)), false);
    final msg = marketClosedMessage(DateTime.utc(2026, 10, 10, 12, 0));
    expect(msg, contains('weekend'));
    expect(metalsReopensAt(DateTime.utc(2026, 10, 9, 21, 30)),
        DateTime.utc(2026, 10, 11, 21, 0));
    expect(metalsReopensAt(DateTime.utc(2026, 10, 11, 12, 0)),
        DateTime.utc(2026, 10, 11, 21, 0));
  });

  test('next session skips open ones', () {
    final t = DateTime.utc(2026, 10, 7, 10, 0); // London open, NY closed
    expect(nextSession(t), ('New York', 13));
  });
}
