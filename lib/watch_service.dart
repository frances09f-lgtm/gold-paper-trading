import 'dart:io';

import 'package:flutter/services.dart';

/// Bridge to the native Android foreground watch service (spec 35,
/// "always watching" mode). Implemented in MainActivity/OroWatchService.kt
/// with no new Flutter plugin, so no new dependency risk. The service only
/// keeps the process alive with a persistent notification while positions
/// are open; all TP/SL/alert checking stays in the existing Dart worker.
class WatchService {
  static const MethodChannel _ch = MethodChannel('oro/watch');
  static String? _lastText;
  static bool _running = false;

  /// Starts the foreground service while [openPositions] > 0 and stops it
  /// when nothing is open. Safe to call on every refresh; it no-ops unless
  /// the state or text actually changed, and any platform error is swallowed
  /// so the watch feature can never break the app.
  static Future<void> sync(int openPositions) async {
    if (!Platform.isAndroid) return;
    final text = openPositions <= 0
        ? null
        : openPositions == 1
            ? 'Watching 1 open position'
            : 'Watching $openPositions open positions';
    if (text == _lastText && (text != null) == _running) return;
    _lastText = text;
    _running = text != null;
    try {
      if (text == null) {
        await _ch.invokeMethod('stop');
      } else {
        await _ch.invokeMethod('start', {'text': text});
      }
    } catch (_) {
      // Never let the watch service interfere with position checking.
    }
  }
}
