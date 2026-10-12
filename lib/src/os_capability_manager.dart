/// OS Capability Manager
///
/// Tracks Android/iOS OS-level state relevant to background sleep tracking:
///   - Battery optimization status (Android)
///   - Motion / activity permission
///   - Notification permission
///   - Background execution availability
///
/// The diagnostics page reads [OSCapabilityManager.report] to show the user
/// why automatic sleep tracking may be unreliable on their device.
///
/// Platform note:
///   This implementation covers Android checks via the platform channel.
///   iOS background execution rules differ significantly and are not yet
///   implemented; iOS support requires a separate native integration sprint.
library;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'sleep_signals.dart';

// ─── Report ───────────────────────────────────────────────────────────────────

class OSCapabilityReport {
  /// Whether the app is excluded from Android battery optimization.
  /// When false, the OS may kill the foreground service during deep Doze.
  /// Always null on iOS (not applicable in the same way).
  final bool? isExemptFromBatteryOptimization;

  /// Whether the notification permission is granted.
  /// Required for the foreground service notification on Android 13+.
  final bool notificationPermissionGranted;

  /// Whether the activity recognition / motion permission is granted.
  final bool activityPermissionGranted;

  /// Platform string: 'android' | 'ios' | 'unknown'.
  final String platform;

  /// Any OS-level warning to surface to the user.
  final String? warning;

  const OSCapabilityReport({
    this.isExemptFromBatteryOptimization,
    required this.notificationPermissionGranted,
    required this.activityPermissionGranted,
    required this.platform,
    this.warning,
  });

  bool get hasIssues {
    if (isExemptFromBatteryOptimization == false) return true;
    if (!notificationPermissionGranted) return true;
    if (!activityPermissionGranted) return true;
    return false;
  }

  List<String> get issues {
    final list = <String>[];
    if (isExemptFromBatteryOptimization == false) {
      list.add(
        'Battery optimization is ON — the OS may kill sleep tracking during deep Doze. '
        'Go to Settings → Battery → App Optimization → this app → Don\'t optimize.',
      );
    }
    if (!notificationPermissionGranted) {
      list.add(
        'Notification permission not granted. The foreground service notification '
        'is required for reliable background tracking on Android 13+.',
      );
    }
    if (!activityPermissionGranted) {
      list.add(
        'Activity recognition permission not granted. '
        'This reduces sleep detection accuracy.',
      );
    }
    return list;
  }

  String get summary {
    if (!hasIssues) return '✅ All required OS permissions and capabilities are active.';
    return '⚠️ ${issues.length} issue(s) may affect automatic sleep tracking.';
  }
}

// ─── Manager ──────────────────────────────────────────────────────────────────

class OSCapabilityManager {
  OSCapabilityManager._();

  static const MethodChannel _channel = SleepSignals.channel;

  static OSCapabilityReport? _cached;

  static OSCapabilityReport? get current => _cached;

  /// Checks OS capabilities and caches the result.
  /// Call once during app startup and refresh after permission dialogs.
  static Future<OSCapabilityReport> check() async {
    final report = await _check();
    _cached = report;
    return report;
  }

  static Future<OSCapabilityReport> _check() async {
    // ── Notification permission ────────────────────────────────────────────
    bool notifGranted = true;
    try {
      final status = await Permission.notification.status;
      notifGranted = status.isGranted;
    } catch (_) {}

    // ── Activity recognition permission ───────────────────────────────────
    bool activityGranted = true;
    try {
      final status = await Permission.activityRecognition.status;
      activityGranted = status.isGranted;
    } catch (_) {}

    // ── Battery optimization (Android only) ───────────────────────────────
    bool? batteryExempt;
    String platform = 'unknown';
    String? warning;

    try {
      final result = await _channel
          .invokeMethod<bool>('isBatteryOptimizationExempt')
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (result != null) {
        batteryExempt = result;
        platform = 'android';
      } else {
        // Channel returned null — likely iOS or channel not available.
        platform = 'ios';
        warning =
            'iOS background execution for continuous sensor collection is subject '
            'to Apple\'s background mode restrictions. Automatic sleep tracking '
            'accuracy on iOS has not yet been fully tested.';
      }
    } on MissingPluginException {
      platform = 'unknown';
    } catch (_) {
      platform = 'unknown';
    }

    return OSCapabilityReport(
      isExemptFromBatteryOptimization: batteryExempt,
      notificationPermissionGranted: notifGranted,
      activityPermissionGranted: activityGranted,
      platform: platform,
      warning: warning,
    );
  }

  /// Requests the missing permissions. Returns the updated report.
  static Future<OSCapabilityReport> requestMissingPermissions() async {
    try {
      await Permission.notification.request();
      await Permission.activityRecognition.request();
    } catch (_) {}
    return check();
  }
}
