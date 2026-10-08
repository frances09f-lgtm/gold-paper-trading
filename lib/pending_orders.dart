import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PendingPaperOrder {
  final String id, side;
  final double qty, trigger;
  final bool above, gtc;
  final double? tp, sl;
  final int createdAt, expiresAt;
  String status;
  String? note;
  PendingPaperOrder({
    required this.id,
    required this.side,
    required this.qty,
    required this.trigger,
    required this.above,
    required this.gtc,
    required this.createdAt,
    required this.expiresAt,
    this.tp,
    this.sl,
    this.status = 'pending',
    this.note,
  });
  bool matches(double quote, int now) =>
      status == 'pending' &&
      (gtc || now < expiresAt) &&
      (above ? quote >= trigger : quote <= trigger);
  Map<String, dynamic> toJson() => {
    'id': id,
    'side': side,
    'qty': qty,
    'trigger': trigger,
    'above': above,
    'gtc': gtc,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
    'tp': tp,
    'sl': sl,
    'status': status,
    'note': note,
  };
  factory PendingPaperOrder.fromJson(Map j) => PendingPaperOrder(
    id: j['id'],
    side: j['side'],
    qty: (j['qty'] as num).toDouble(),
    trigger: (j['trigger'] as num).toDouble(),
    above: j['above'],
    gtc: j['gtc'],
    createdAt: j['createdAt'],
    expiresAt: j['expiresAt'],
    tp: (j['tp'] as num?)?.toDouble(),
    sl: (j['sl'] as num?)?.toDouble(),
    status: j['status'],
    note: j['note'],
  );
}

class PendingPaperOrders {
  static const key = 'oro_pending_paper_orders';
  final SharedPreferences prefs;
  final List<PendingPaperOrder> orders;
  bool evaluating = false;
  PendingPaperOrders(this.prefs, this.orders);
  static PendingPaperOrders load(SharedPreferences prefs) {
    final out = <PendingPaperOrder>[];
    try {
      for (final j in jsonDecode(prefs.getString(key) ?? '[]') as List) {
        final o = PendingPaperOrder.fromJson(j as Map);
        if (o.status == 'submitting') {
          o.status = 'needsReview';
          o.note = 'App stopped during submission. Check positions before placing another order.';
        }
        out.add(o);
      }
    } catch (_) {}
    return PendingPaperOrders(prefs, out);
  }

  Future<void> save() async {
    final saved = await prefs.setString(
      key,
      jsonEncode(orders.map((o) => o.toJson()).toList()),
    );
    if (!saved) throw StateError('Pending order storage failed');
  }

  Future<void> cancel(String id) async {
    final o = orders.firstWhere((o) => o.id == id);
    if (o.status == 'pending') {
      o.status = 'cancelled';
      await save();
    }
  }

  Future<void> evaluate({
    required double bid,
    required double ask,
    required bool fresh,
    required bool active,
    required int now,
    required Future<String?> Function(PendingPaperOrder) submit,
  }) async {
    if (evaluating || !fresh || !active || !bid.isFinite || !ask.isFinite)
      return;
    evaluating = true;
    try {
      for (final o in List<PendingPaperOrder>.of(orders)) {
        if (o.status != 'pending') continue;
        if (!o.gtc && now >= o.expiresAt) {
          o.status = 'expired';
          await save();
          continue;
        }
        if (!o.matches(o.side == 'buy' ? ask : bid, now)) continue;
        o.status = 'submitting';
        await save();
        try {
          final result = await submit(o);
          o.status = result == null ? 'filled' : 'needsReview';
          o.note = result;
        } catch (_) {
          o.status = 'needsReview';
          o.note = 'Submission outcome unknown. Check positions. No automatic retry.';
        }
        await save();
      }
    } finally {
      evaluating = false;
    }
  }
}
