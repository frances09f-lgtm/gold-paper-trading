import 'package:flutter_test/flutter_test.dart';
import 'package:gold_paper_trading/alerts.dart';

void main() {
  test('above alert fires at or over level, only once', () {
    final a = PriceAlert(
        id: '1', level: 4200, above: true, createdAt: DateTime(2026));
    expect(a.check(4199), isFalse);
    expect(a.triggered, isFalse);
    expect(a.check(4200), isTrue);
    expect(a.triggered, isTrue);
    expect(a.check(4250), isFalse); // already fired
  });

  test('below alert fires at or under level', () {
    final a = PriceAlert(
        id: '2', level: 4100, above: false, createdAt: DateTime(2026));
    expect(a.check(4101), isFalse);
    expect(a.check(4100), isTrue);
  });

  test('json round-trip preserves state', () {
    final a = PriceAlert(
        id: '3',
        level: 4150.5,
        above: true,
        createdAt: DateTime(2026, 10, 6, 12),
        triggered: true,
        triggeredAt: DateTime(2026, 10, 6, 13));
    final b = PriceAlert.fromJson(a.toJson())!;
    expect(b.level, 4150.5);
    expect(b.above, isTrue);
    expect(b.triggered, isTrue);
    expect(b.triggeredAt, a.triggeredAt);
    expect(PriceAlert.fromJson({'junk': 1}), isNull);
  });
}
