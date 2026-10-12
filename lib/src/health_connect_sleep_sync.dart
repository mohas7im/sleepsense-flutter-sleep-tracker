/// Syncs sleep sessions from Health Connect (Android) into the same
/// `sleep_auto_sessions` table the phone-heuristic detector writes to.
///
/// Why this exists: [SleepDetectionService] can only ever guess sleep from
/// phone motion/screen signals — it explicitly cannot do real sleep-stage
/// detection. Health Connect, by contrast, surfaces sleep sessions already
/// measured by purpose-built sources: wearables (Fitbit, Galaxy Watch, Mi
/// Band, ...), Samsung Health, or a Pixel's own on-device Bedtime tracking
/// (Digital Wellbeing) — all of which write into Health Connect automatically
/// once the user enables them, no wearable required for the Pixel case.
///
/// This is intentionally Android-only for now: `HealthDataType.SLEEP_SESSION`
/// has no iOS/HealthKit equivalent — on iOS you'd reconstruct a session from
/// individual `SLEEP_ASLEEP`/`SLEEP_AWAKE` category samples, which is a
/// separate piece of work not needed for this app's current platform focus.
library;

import 'dart:io';

import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sleep_repository.dart';
import 'sleep_session.dart';

class HealthConnectSleepSync {
  HealthConnectSleepSync._();

  static const _prefKeyEnabled = 'health_connect_sleep_sync_enabled';
  static const _prefKeyLastSync = 'health_connect_sleep_last_sync_ms';
  static const _prefKeyNudgeDismissed = 'health_connect_sleep_nudge_dismissed';

  static final Health _health = Health();
  static bool _configured = false;

  static Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// Whether the user has opted into Health Connect sync (persisted setting).
  /// This is separate from whether Health Connect *permission* has actually
  /// been granted — [hasPermission] checks that.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyEnabled) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyEnabled, value);
  }

  /// Whether the user has permanently dismissed the "connect Health Connect"
  /// nudge shown on the Sleep screen. One-way — there's no un-dismiss; if the
  /// user wants it back they can still find the toggle in Sleep Settings.
  static Future<bool> isNudgeDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyNudgeDismissed) ?? false;
  }

  static Future<void> dismissNudge() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyNudgeDismissed, true);
  }

  static Future<DateTime?> lastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefKeyLastSync);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Android-only: Health Connect has no iOS equivalent for this feature.
  static bool get isSupportedPlatform => Platform.isAndroid;

  /// Whether the Health Connect app/SDK itself is installed and usable.
  /// False (not an error) on devices without Google Play Services.
  static Future<bool> isHealthConnectAvailable() async {
    if (!isSupportedPlatform) return false;
    await _ensureConfigured();
    try {
      return await _health.isHealthConnectAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Opens the Play Store listing for Health Connect.
  static Future<void> promptInstallHealthConnect() async {
    if (!isSupportedPlatform) return;
    await _ensureConfigured();
    await _health.installHealthConnect();
  }

  static Future<bool> hasPermission() async {
    if (!isSupportedPlatform) return false;
    await _ensureConfigured();
    try {
      final granted = await _health.hasPermissions([HealthDataType.SLEEP_SESSION]);
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests read access to sleep data. Must be called from a user-initiated
  /// action (a settings toggle) — never automatically on app start, since it
  /// pops a system permission dialog.
  static Future<bool> requestPermission() async {
    if (!isSupportedPlatform) return false;
    await _ensureConfigured();
    try {
      return await _health.requestAuthorization([HealthDataType.SLEEP_SESSION]);
    } catch (_) {
      return false;
    }
  }

  /// Pulls sleep sessions from Health Connect for the last [days] days and
  /// upserts them into [repository]. Safe to call opportunistically (app
  /// foreground, pull-to-refresh) — a no-op if not enabled/permitted, and
  /// idempotent (re-syncing the same period just replaces the same rows,
  /// see [SleepSession.fromHealthConnect]).
  ///
  /// Returns the number of sessions synced, or -1 if sync was skipped
  /// (not enabled, not permitted, or Health Connect unavailable).
  static Future<int> syncRecentSessions(
    SleepRepository repository, {
    int days = 30,
  }) async {
    if (!isSupportedPlatform) return -1;
    if (!await isEnabled()) return -1;
    if (!await hasPermission()) return -1;

    await _ensureConfigured();

    final now = DateTime.now();
    // Health Connect restricts reads to 30 days back from when permission
    // was granted regardless of what's requested here — days is a request
    // ceiling, not a guarantee.
    final start = now.subtract(Duration(days: days));

    List<HealthDataPoint> points;
    try {
      points = await _health.getHealthDataFromTypes(
        types: [HealthDataType.SLEEP_SESSION],
        startTime: start,
        endTime: now,
      );
    } catch (_) {
      return -1;
    }

    if (points.isEmpty) return 0;

    final sessions = points
        .map((p) => SleepSession.fromHealthConnect(
              // uuid is already unique per Health Connect record; sourceId
              // distinguishes which app/device wrote it, folded in so two
              // different sources' records for an overlapping time never
              // collide on id.
              recordUuid: '${p.sourceId}_${p.uuid}',
              start: p.dateFrom,
              end: p.dateTo,
              createdAt: now.millisecondsSinceEpoch,
            ))
        .where((s) => s.durationMinutes > 0)
        .toList();

    await repository.saveHealthConnectSessions(sessions);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyLastSync, now.millisecondsSinceEpoch);

    return sessions.length;
  }
}
