/// Economic calendar (spec 34). Real scheduled events only: the free
/// FairEconomy mirror of the ForexFactory weekly calendar (no API key).
/// On any failure the UI shows "News data unavailable" - events are
/// never fabricated.
import 'dart:convert';

import 'package:http/http.dart' as http;

class EconEvent {
  final String title;
  final DateTime time;
  final String impact; // High / Medium / Low / Holiday
  final String forecast;
  final String previous;
  const EconEvent(this.title, this.time, this.impact, this.forecast, this.previous);
}

Future<List<EconEvent>> fetchUsdCalendar() async {
  final r = await http
      .get(Uri.parse(
          'https://nfs.faireconomy.media/ff_calendar_thisweek.json'))
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw StateError('calendar http ${r.statusCode}');
  final list = jsonDecode(r.body) as List;
  final out = <EconEvent>[];
  for (final e in list) {
    final m = e as Map<String, dynamic>;
    if (m['country'] != 'USD') continue;
    final t = DateTime.tryParse(m['date']?.toString() ?? '')?.toLocal();
    if (t == null) continue;
    out.add(EconEvent(
      m['title']?.toString() ?? 'Event',
      t,
      m['impact']?.toString() ?? '',
      m['forecast']?.toString() ?? '',
      m['previous']?.toString() ?? '',
    ));
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}
