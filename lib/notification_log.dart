import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Mirror of the app palette (kept local so the background worker's isolate
// can use this file without importing the whole app).
const _cBg = Color(0xFF0F1115);
const _cCard = Color(0xFF171A21);
const _cDim = Color(0xFF8A93A5);
const _cGreen = Color(0xFF2ECC71);
const _cRed = Color(0xFFFF5A5F);

/// One past notification (TP/SL hit, price alert) with its time and details.
class NotificationLogEntry {
  final String title;
  final String body;
  final DateTime at;

  const NotificationLogEntry({
    required this.title,
    required this.body,
    required this.at,
  });

  Map<String, dynamic> toJson() =>
      {'title': title, 'body': body, 'at': at.toIso8601String()};

  static NotificationLogEntry fromJson(Map<String, dynamic> j) =>
      NotificationLogEntry(
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// On-device history of every notification Oro posts, written by the single
/// _notify funnel so foreground AND background-worker notifications are both
/// recorded. Stored locally only, capped at the most recent 100.
class NotificationLog {
  static const _key = 'tj_notification_log';
  static const _seenKey = 'tj_notification_log_seen';
  static const _cap = 100;

  static Future<void> add(String title, String body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = read(prefs);
      entries.insert(
          0,
          NotificationLogEntry(
              title: title, body: body, at: DateTime.now()));
      if (entries.length > _cap) entries.removeRange(_cap, entries.length);
      await prefs.setString(
          _key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {
      // Logging must never break notification delivery.
    }
  }

  static List<NotificationLogEntry> read(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) =>
              NotificationLogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static int unread(SharedPreferences prefs) {
    final seenRaw = prefs.getString(_seenKey);
    final seen = seenRaw == null ? null : DateTime.tryParse(seenRaw);
    final entries = read(prefs);
    if (seen == null) return entries.length;
    return entries.where((e) => e.at.isAfter(seen)).length;
  }

  static Future<void> markSeen(SharedPreferences prefs) async {
    await prefs.setString(_seenKey, DateTime.now().toIso8601String());
  }

  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(_key);
    await prefs.setString(_seenKey, DateTime.now().toIso8601String());
  }
}

String _fmtWhen(DateTime at) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(at.hour)}:${two(at.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == today) return 'Today $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $hm';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[at.month - 1]} ${at.day}, $hm';
}

class NotificationHistoryScreen extends StatefulWidget {
  const NotificationHistoryScreen({super.key});

  @override
  State<NotificationHistoryScreen> createState() =>
      _NotificationHistoryScreenState();
}

class _NotificationHistoryScreenState extends State<NotificationHistoryScreen> {
  List<NotificationLogEntry> _entries = [];
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await NotificationLog.markSeen(prefs);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _entries = NotificationLog.read(prefs);
    });
  }

  Future<void> _clear() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await NotificationLog.clear(prefs);
    if (!mounted) return;
    setState(() => _entries = []);
  }

  Color _accentFor(NotificationLogEntry e) {
    final t = e.title.toLowerCase();
    if (t.contains('take profit')) return _cGreen;
    if (t.contains('stop loss')) return _cRed;
    return Colors.amber;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cBg,
      appBar: AppBar(
        backgroundColor: _cBg,
        elevation: 0,
        title: const Text('Notifications',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          if (_entries.isNotEmpty)
            TextButton(
              onPressed: _clear,
              child: const Text('Clear', style: TextStyle(color: _cDim)),
            ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(
              child: Text('No notifications yet',
                  style: TextStyle(color: _cDim, fontSize: 15)))
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Color(0xFF232733)),
              itemBuilder: (context, i) {
                final e = _entries[i];
                return Container(
                  color: _cCard,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(top: 6, right: 12),
                        decoration: BoxDecoration(
                          color: _accentFor(e),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.title,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                            if (e.body.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(e.body,
                                    style: const TextStyle(
                                        fontSize: 13, color: _cDim)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_fmtWhen(e.at),
                          style:
                              const TextStyle(fontSize: 12, color: _cDim)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
