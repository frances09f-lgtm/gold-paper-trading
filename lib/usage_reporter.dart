import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Coarse telemetry for the owner's personal dashboard.
/// Reports event COUNTS only: app starts, AI calls, trade opens/closes.
/// Never sends prices, positions, balances, messages, or account details.
/// Fire-and-forget: any failure is swallowed - the app works identically
/// with no network, and telemetry can never break trading.
class UsageReporter {
  static const _url =
      'https://ncaialkmxhbtarmhoiei.supabase.co/rest/v1/app_usage';
  static const _key = 'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';
  static String? _device;

  static Future<String> _deviceId() async {
    if (_device != null) return _device!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString('usage_device_id');
    if (id == null) {
      id = 'dev-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      await p.setString('usage_device_id', id);
    }
    _device = id;
    return id;
  }

  static void report(String kind, [Map<String, dynamic>? meta]) {
    () async {
      try {
        final device = await _deviceId();
        await http
            .post(Uri.parse(_url),
                headers: {
                  'apikey': _key,
                  'Authorization': 'Bearer $_key',
                  'Content-Type': 'application/json',
                  'Prefer': 'return=minimal',
                },
                body: jsonEncode({
                  'app': 'oro',
                  'device': device,
                  'kind': kind,
                  'meta': meta ?? const {},
                }))
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // telemetry must never affect the app
      }
    }();
  }
}
