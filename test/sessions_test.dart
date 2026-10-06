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

  test('next session skips open ones', () {
    final t = DateTime.utc(2026, 10, 7, 10, 0); // London open, NY closed
    expect(nextSession(t), ('New York', 13));
  });
}
