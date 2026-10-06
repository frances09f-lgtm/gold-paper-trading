import 'package:flutter/material.dart';

/// Spec 33: market session display for Sydney, Tokyo, London, New York.
///
/// Spot gold (XAU/USD) is OTC - there are no official exchange session
/// hours and brokers/providers differ, so these are widely used REFERENCE
/// windows in UTC, labeled approximate in the UI. Weekdays only: the metals
/// market is closed from Friday evening to Sunday evening (UTC).
class SessionWindow {
  final String name;
  final int openHourUtc; // inclusive
  final int closeHourUtc; // exclusive; may wrap past midnight
  const SessionWindow(this.name, this.openHourUtc, this.closeHourUtc);
}

const sessionWindows = [
  SessionWindow('Sydney', 21, 6),
  SessionWindow('Tokyo', 0, 9),
  SessionWindow('London', 8, 17),
  SessionWindow('New York', 13, 22),
];

class SessionState {
  final String name;
  final bool open;
  const SessionState(this.name, this.open);
}

bool _isWeekendUtc(DateTime utc) =>
    utc.weekday == DateTime.saturday || utc.weekday == DateTime.sunday;

bool isSessionOpen(SessionWindow w, DateTime utc) {
  if (_isWeekendUtc(utc)) return false;
  final h = utc.hour;
  return w.openHourUtc < w.closeHourUtc
      ? (h >= w.openHourUtc && h < w.closeHourUtc)
      : (h >= w.openHourUtc || h < w.closeHourUtc); // wraps midnight
}

List<SessionState> sessionsNow(DateTime utc) =>
    sessionWindows.map((w) => SessionState(w.name, isSessionOpen(w, utc))).toList();

/// Name + hour of the next session to open, or null if all are open.
(String, int)? nextSession(DateTime utc) {
  if (_isWeekendUtc(utc)) return ('Sydney', 21); // Sunday 21:00 UTC
  final closed =
      sessionWindows.where((w) => !isSessionOpen(w, utc)).toList();
  if (closed.isEmpty) return null;
  final h = utc.hour;
  SessionWindow? best;
  int bestWait = 49;
  for (final w in closed) {
    var wait = (w.openHourUtc - h) % 24;
    if (wait == 0) wait = 24;
    if (wait < bestWait) {
      bestWait = wait;
      best = w;
    }
  }
  return best == null ? null : (best.name, best.openHourUtc);
}

/// Compact strip: one dot-labeled chip per session, plus a caption with the
/// currently open sessions and the next one to open.
class SessionsStrip extends StatelessWidget {
  const SessionsStrip({super.key});

  /// Test hook: deterministic clock for golden renders.
  static DateTime Function()? debugNow;

  @override
  Widget build(BuildContext context) {
    final now = (debugNow ?? () => DateTime.now().toUtc())();
    final states = sessionsNow(now);
    final openNames =
        states.where((s) => s.open).map((s) => s.name).toList();
    final next = nextSession(now);
    final caption = _isWeekendUtc(now)
        ? 'Metals market closed for the weekend'
        : openNames.isEmpty
            ? 'Between sessions'
            : 'Open now: ${openNames.join(', ')}';
    const cDim = Color(0xFF8A93A5);
    const cGreen = Color(0xFF2ECC71);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF171A21),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (final s in states)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: s.open ? cGreen : const Color(0xFF3A4152),
                  ),
                ),
                const SizedBox(width: 4),
                Text(s.name,
                    style: TextStyle(
                        fontSize: 11,
                        color: s.open ? Colors.white : cDim,
                        fontWeight:
                            s.open ? FontWeight.w600 : FontWeight.normal)),
              ]),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
          '$caption${next != null ? ' · Next: ${next.$1} ${next.$2.toString().padLeft(2, '0')}:00 UTC' : ''} · reference hours, approximate',
          style: const TextStyle(fontSize: 10, color: cDim),
        ),
      ]),
    );
  }
}

/// Spot gold's real closures: a daily settlement break 21:00-22:00 UTC on
/// weekdays, and the weekend from Friday 21:00 UTC to Sunday 21:00 UTC.
/// Feeds keep serving the last pre-close tick during these windows, so a
/// stale quote inside one of them means "market closed", not "feed dead".
bool metalsMarketClosed(DateTime utc) {
  if (utc.weekday == DateTime.saturday) return true;
  if (utc.weekday == DateTime.sunday && utc.hour < 21) return true;
  if (utc.weekday == DateTime.friday && utc.hour >= 21) return true;
  // Weekday daily settlement break (Sunday 21:00 is the weekly OPEN).
  return utc.weekday != DateTime.saturday &&
      utc.weekday != DateTime.sunday &&
      utc.hour == 21;
}

bool _isWeekendClose(DateTime utc) =>
    utc.weekday == DateTime.saturday ||
    utc.weekday == DateTime.sunday ||
    (utc.weekday == DateTime.friday && utc.hour >= 21);

/// The UTC instant the market reopens after the current closure.
DateTime metalsReopensAt(DateTime utc) {
  if (_isWeekendClose(utc)) {
    var d = DateTime.utc(utc.year, utc.month, utc.day, 21);
    while (d.isBefore(utc) || d.weekday != DateTime.sunday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }
  return DateTime.utc(utc.year, utc.month, utc.day, 22);
}

String fmtLocalShort(DateTime utcInstant) {
  final l = utcInstant.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final ampm = l.hour < 12 ? 'AM' : 'PM';
  final mm = l.minute.toString().padLeft(2, '0');
  final today = DateTime.now();
  final sameDay =
      l.year == today.year && l.month == today.month && l.day == today.day;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final prefix = sameDay ? '' : '${days[l.weekday - 1]} ';
  return '$prefix$h12:$mm $ampm';
}

/// Human explanation when the metals market is closed, else null.
String? marketClosedMessage([DateTime? now]) {
  final utc = (now ?? DateTime.now()).toUtc();
  if (!metalsMarketClosed(utc)) return null;
  final re = fmtLocalShort(metalsReopensAt(utc));
  return _isWeekendClose(utc)
      ? 'Market closed for the weekend - reopens $re'
      : 'Market on its daily 1-hour break - reopens $re';
}
