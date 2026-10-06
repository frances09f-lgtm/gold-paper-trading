/// Stage (e): price alerts. Device-local (SharedPreferences), triggered
/// against the real mid price on each quote refresh. No push plugin - a
/// triggered alert shows as an in-app banner until dismissed.

class PriceAlert {
  final String id;
  final double level;
  final bool above; // trigger when price >= level; else price <= level
  final DateTime createdAt;
  bool triggered;
  DateTime? triggeredAt;

  PriceAlert({
    required this.id,
    required this.level,
    required this.above,
    required this.createdAt,
    this.triggered = false,
    this.triggeredAt,
  });

  /// Evaluate against a fresh real price. Only transitions false->true.
  bool check(double price) {
    if (triggered) return false;
    final hit = above ? price >= level : price <= level;
    if (hit) {
      triggered = true;
      triggeredAt = DateTime.now();
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'level': level,
        'above': above,
        'createdAt': createdAt.toIso8601String(),
        'triggered': triggered,
        'triggeredAt': triggeredAt?.toIso8601String(),
      };

  static PriceAlert? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final level = (j['level'] as num?)?.toDouble();
    final above = j['above'];
    final created = DateTime.tryParse(j['createdAt']?.toString() ?? '');
    if (id == null || level == null || above is! bool || created == null) {
      return null;
    }
    return PriceAlert(
      id: id,
      level: level,
      above: above,
      createdAt: created,
      triggered: j['triggered'] == true,
      triggeredAt: DateTime.tryParse(j['triggeredAt']?.toString() ?? ''),
    );
  }
}
