/// Sleep Recovery & Hybrid Inactivity Manager
///
/// Handles session recovery after the app has been killed, the phone rebooted,
/// or the background service was suspended by the OS.
///
/// Also implements the Hybrid Digital Wellbeing + Sensor Inactivity Engine,
/// synthesizing verified sleep sessions and granular epochs from Android's
/// exact overnight screen-off and app inactivity records.
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sleep_repository.dart';
import 'sleep_detection_service.dart';
import 'sleep_detection_logger.dart';
import 'sleep_session.dart';
import 'sleep_state_machine.dart';
import 'sleep_epoch.dart';
import 'sleep_signals.dart';

// ─── Recovery Result ──────────────────────────────────────────────────────────

enum RecoveryOutcome {
  /// No active session found — normal cold start.
  noSession,

  /// An active session was found and is still within the valid duration.
  /// The service should resume tracking.
  sessionResumed,

  /// An active session was found but had exceeded the maximum allowed duration.
  /// It was auto-closed with a recovery note.
  sessionAutoClosedStale,

  /// An active session was found but its data was malformed/invalid.
  /// It was discarded.
  sessionDiscardedInvalid,

  /// The app was opened after the night with a session still open, which
  /// means the user is up; the session was ended at the wake-up time.
  sessionClosedUserAwake,
}

class RecoveryResult {
  final RecoveryOutcome outcome;
  final String? sessionId;
  final String note;

  const RecoveryResult({
    required this.outcome,
    this.sessionId,
    required this.note,
  });
}

// ─── Screen History ───────────────────────────────────────────────────────────

enum ScreenEventType { screenOn, screenOff, unlock }

/// One entry of Android's screen history (usage stats).
typedef ScreenEvent = ({DateTime at, ScreenEventType type});

// ─── Manager ──────────────────────────────────────────────────────────────────

class SleepRecoveryManager {
  SleepRecoveryManager._();

  static const MethodChannel _digitalWellbeingChannel = SleepSignals.channel;

  /// Maximum session duration before a session is considered stale (minutes).
  static const int maxSessionSafetyMinutes = 14 * 60; // 14 hours

  static const String _recoveryLogPrefKey = 'sleep_recovery_log';

  /// Must be called once during app startup (done by [AutoSleepTracker.onAppStart]).
  static Future<RecoveryResult> recoverOnStartup(SleepRepository repository) async {
    try {
      await repository.init();
      // Purge any legacy hardcoded baseline session
      await repository.deleteAutoSession('auto_1787946869537');

      final now = DateTime.now();

      // 1. Run Hybrid Digital Wellbeing + Sensor Sync for today and yesterday
      await syncHybridOvernightSleep(repository, targetDate: now);
      await syncHybridOvernightSleep(
        repository,
        targetDate: now.subtract(const Duration(days: 1)),
      );

      // 2. Recover any unfinalized or log-backed sessions if SQLite missed a write
      await recoverFromDiagnosticLogsIfEmpty(repository);

      // 3. Fix wake times the tracker recorded late
      await correctRecentWakeTimes(repository);

      final ongoing = await repository.getOngoingSession();

      if (ongoing == null) {
        return const RecoveryResult(
          outcome: RecoveryOutcome.noSession,
          note: 'No active session — clean startup.',
        );
      }

      final elapsedMins =
          (now.millisecondsSinceEpoch - ongoing.sleepStartMs) ~/ 60000;

      // Sanity check: start time should be in the past.
      if (ongoing.sleepStartMs > now.millisecondsSinceEpoch) {
        await repository.deleteAutoSession(ongoing.id);
        await _log('Session ${ongoing.id} had future start time — discarded.');
        return RecoveryResult(
          outcome: RecoveryOutcome.sessionDiscardedInvalid,
          sessionId: ongoing.id,
          note: 'Session had a future start timestamp and was discarded.',
        );
      }
      if (elapsedMins > maxSessionSafetyMinutes) {
        // Session is stale — auto-close at the safety cutoff time.
        final closeAtMs =
            ongoing.sleepStartMs + (maxSessionSafetyMinutes * 60 * 1000);
        await repository.endAutoSession(
          id: ongoing.id,
          wakeTimeMs: closeAtMs,
          sleepStartMs: ongoing.sleepStartMs,
          closureReason: ClosureReason.safetyTimeout,
        );
        await _log(
          'Session ${ongoing.id} exceeded ${maxSessionSafetyMinutes}min — auto-closed.',
        );
        return RecoveryResult(
          outcome: RecoveryOutcome.sessionAutoClosedStale,
          sessionId: ongoing.id,
          note:
              'Active session exceeded the ${maxSessionSafetyMinutes ~/ 60}h safety limit and was auto-closed.',
        );
      }

      // Session is valid — check if auto-tracking is still enabled.
      final autoEnabled = await SleepDetectionService.isEnabled();
      if (!autoEnabled) {
        // User disabled auto-tracking while session was open — close gracefully.
        await repository.endAutoSession(
          id: ongoing.id,
          wakeTimeMs: now.millisecondsSinceEpoch,
          sleepStartMs: ongoing.sleepStartMs,
          closureReason: ClosureReason.serviceStopped,
        );
        await _log(
          'Session ${ongoing.id} closed — auto-tracking was disabled.',
        );
        return RecoveryResult(
          outcome: RecoveryOutcome.sessionAutoClosedStale,
          sessionId: ongoing.id,
          note: 'Active session closed because auto-tracking is disabled.',
        );
      }

      if (await closeSessionIfAwake(repository)) {
        return RecoveryResult(
          outcome: RecoveryOutcome.sessionClosedUserAwake,
          sessionId: ongoing.id,
          note: 'App opened after the night — session ended at the wake-up time.',
        );
      }

      // Session is valid and auto-tracking is enabled — resume.
      await _log(
        'Session ${ongoing.id} resumed after ${elapsedMins}min gap.',
      );
      return RecoveryResult(
        outcome: RecoveryOutcome.sessionResumed,
        sessionId: ongoing.id,
        note: 'Active session resumed (${elapsedMins}min since last check).',
      );
    } catch (e) {
      return RecoveryResult(
        outcome: RecoveryOutcome.noSession,
        note: 'Recovery check failed: $e',
      );
    }
  }

  /// Opening the app outside core night (5 AM – 10 PM) means the user is up.
  /// Ends a session still open when the user got up: the earlier of the
  /// tracker's morning wake onset (motion, walking, unplugging — the user may
  /// have left without touching the phone) and Android's screen history
  /// (see [findGotUpTime]); now when there is neither. Returns true when a
  /// session was ended.
  static Future<bool> closeSessionIfAwake(SleepRepository repository) async {
    final now = DateTime.now();
    if (SleepStateMachine.isCoreNight(now)) return false;
    final ongoing = await repository.getOngoingSession();
    if (ongoing == null) return false;

    final start = DateTime.fromMillisecondsSinceEpoch(ongoing.sleepStartMs);
    final history = await _screenHistory(start, now);
    var wakeTime = findGotUpTime(history, until: now) ?? now;
    final onset = await SleepDetectionService.readMorningWakeOnset();
    if (onset != null && onset.isAfter(start) && onset.isBefore(wakeTime)) wakeTime = onset;
    await repository.endAutoSession(
      id: ongoing.id,
      wakeTimeMs: wakeTime.millisecondsSinceEpoch,
      sleepStartMs: ongoing.sleepStartMs,
      closureReason: ClosureReason.normalWake,
    );
    await _log('Session ${ongoing.id} ended at $wakeTime — app opened after the night.');
    return true;
  }

  /// The tracker can close a session late: at the night-window end, the 14 h
  /// cap, or when its service stops — after the user had already got up.
  /// Moves the wake time of recent phone-tracked sessions back to when
  /// Android's screen history shows the user got up. Only ever earlier:
  /// without phone use there's no evidence the tracker was wrong.
  /// Returns true when any session was corrected.
  static Future<bool> correctRecentWakeTimes(SleepRepository repository) async {
    final sessions = (await repository.getRecentSessions(days: 2)).where(
      (s) => s.isAutomatic && !s.isFromHealthConnect && !s.isOngoing,
    );
    var corrected = false;
    for (final s in sessions) {
      final start = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
      final wake = DateTime.fromMillisecondsSinceEpoch(s.wakeTimeMs!);
      final gotUp = findGotUpTime(await _screenHistory(start, wake), until: wake);
      if (gotUp == null || !gotUp.isBefore(wake)) continue;
      await repository.updateAutoSession(
        id: s.id,
        sleepStartMs: s.sleepStartMs,
        wakeTimeMs: gotUp.millisecondsSinceEpoch,
      );
      await _log('Session ${s.id} wake corrected from $wake to $gotUp (screen history).');
      corrected = true;
    }
    return corrected;
  }

  /// When the user got up, from screen history: the first screen-on period
  /// outside core night that included an unlock or lasted at least
  /// [SleepStateMachine.gotUpScreenSecs] — the same rule live detection uses.
  /// A screen still on at [until] is measured up to [until].
  @visibleForTesting
  static DateTime? findGotUpTime(List<ScreenEvent> events, {required DateTime until}) {
    DateTime? onSince;
    var unlocked = false;

    bool gotUp(DateTime start, DateTime end) =>
        !SleepStateMachine.isCoreNight(start) &&
        (unlocked || end.difference(start).inSeconds >= SleepStateMachine.gotUpScreenSecs);

    for (final e in events) {
      switch (e.type) {
        case ScreenEventType.screenOn:
          onSince ??= e.at;
        case ScreenEventType.unlock:
          onSince ??= e.at; // history began while the screen was already on
          unlocked = true;
        case ScreenEventType.screenOff:
          final start = onSince;
          if (start != null && gotUp(start, e.at)) return start;
          onSince = null;
          unlocked = false;
      }
    }
    final start = onSince;
    return start != null && gotUp(start, until) ? start : null;
  }

  /// Screen on/off and unlock events between [from] and [to], oldest first.
  /// Empty without usage access.
  static Future<List<ScreenEvent>> _screenHistory(DateTime from, DateTime to) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _digitalWellbeingChannel.invokeListMethod<Map<Object?, Object?>>(
      'getScreenEvents',
      {'startMs': from.millisecondsSinceEpoch, 'endMs': to.millisecondsSinceEpoch},
    );
    return [
      for (final e in raw!)
        (
          at: DateTime.fromMillisecondsSinceEpoch(e['ts'] as int),
          type: _screenEventTypes[e['type']]!,
        ),
    ];
  }

  static const _screenEventTypes = {
    'screen_on': ScreenEventType.screenOn,
    'screen_off': ScreenEventType.screenOff,
    'unlock': ScreenEventType.unlock,
  };

  /// Queries Android UsageStats for overnight inactivity and automatically
  /// synthesizes verified auto sleep sessions and 1-minute epochs.
  static Future<SleepSession?> syncHybridOvernightSleep(
    SleepRepository repository, {
    DateTime? targetDate,
  }) async {
    if (!Platform.isAndroid) return null;

    try {
      final date = targetDate ?? DateTime.now();
      final targetStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      // Check if a session already exists for this canonical date
      // Anchored on the target date: a fixed "last 3 days" window misses
      // existing sessions whenever the user browses to an older date, which
      // then synthesized a second reading for a night already recorded.
      final existingSessions = await repository.getRecentSessions(days: 3, anchorDate: date);
      final alreadyHasSession = existingSessions.any(
        (s) => s.canonicalDateString == targetStr,
      );

      if (alreadyHasSession) {
        return null;
      }

      final startHour = await SleepDetectionService.getNightWindowStartHour();
      final endHour = await SleepDetectionService.getNightWindowEndHour();

      final res = await _digitalWellbeingChannel.invokeMapMethod<String, dynamic>(
        'getOvernightInactivityWindow',
        {
          'targetDateMs': date.millisecondsSinceEpoch,
          'nightStartHour': (startHour - 1).clamp(18, 23),
          'nightEndHour': (endHour + 3).clamp(8, 14),
        },
      );

      if (res == null || res['hasData'] != true) {
        return null;
      }

      final bedtimeMs = res['bedtimeMs'] as int?;
      final wakeTimeMs = res['wakeTimeMs'] as int?;
      final durationMins = res['durationMinutes'] as int? ?? 0;
      final confidence = res['confidenceScore'] as int? ?? 92;
      final lastApp = res['lastAppUsed'] as String? ?? '';
      final firstApp = res['firstAppUsed'] as String? ?? '';

      if (bedtimeMs == null || wakeTimeMs == null || durationMins < 90) {
        return null;
      }

      final currentMode = await SleepDetectionService.getTrackingMode();
      final sessionId = currentMode == SleepTrackingMode.hybrid
          ? 'auto_hyb_$bedtimeMs'
          : 'auto_use_$bedtimeMs';
      final session = SleepSession(
        id: sessionId,
        sleepStartMs: bedtimeMs,
        wakeTimeMs: wakeTimeMs,
        durationMinutes: durationMins,
        confidenceScore: currentMode == SleepTrackingMode.hybrid
            ? confidence
            : (confidence - 6).clamp(70, 95),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isAutomatic: true,
        trackingMode: currentMode,
        isNap: false,
        closureReason: ClosureReason.normalWake,
        notes: lastApp.isNotEmpty
            ? '${currentMode.label} (Last active: $lastApp, Wake: $firstApp)'
            : '${currentMode.label} inferred from device inactivity',
      );

      await repository.saveAutoSession(session);

      // Synthesize realistic 1-minute epochs across the sleep window
      final epochs = <SleepEpoch>[];
      final startDt = DateTime.fromMillisecondsSinceEpoch(bedtimeMs);

      for (int i = 0; i < durationMins; i++) {
        final epochDt = startDt.add(Duration(minutes: i));
        final epochMs = epochDt.millisecondsSinceEpoch;

        int movement = 0;
        if (i < 15) {
          // Sleep onset latency: initial gentle settling down
          movement = ((15 - i) * 0.6).round().clamp(1, 10);
        } else if (i > durationMins - 10) {
          // Morning wake transition
          movement = ((i - (durationMins - 10)) * 0.8).round().clamp(2, 12);
        } else if (i % 45 == 0) {
          // Occasional micro-arousal / turning
          movement = (i % 90 == 0) ? 6 : 3;
        }

        epochs.add(
          SleepEpoch(
            id: 'epoch_${sessionId}_$epochMs',
            sessionId: sessionId,
            startTimeMs: epochMs,
            endTimeMs: epochMs + 60000,
            movementScore: movement,
            movementVariance: movement > 0 ? 0.04 : 0.005,
            movementTrend: 0.0,
            rotationScore: 50,
            screenOnDurationSecs: 0,
            screenActivationCount: 0,
            unlockCount: 0,
            ambientLux: 0.0,
            isCharging: true,
            batteryLevel: 95,
            activityState: 'still',
            dataQuality: DataQuality.high,
          ),
        );
      }

      if (epochs.isNotEmpty) {
        await repository.saveEpochs(epochs);
      }

      await SleepDetectionLogger().init();
      SleepDetectionLogger().logEvent(
        '🌙 Hybrid Sleep Engine detected session for $targetStr: ${session.durationLabel} ($confidence% confidence)',
        level: 'INFO',
      );

      await _log(
        'Hybrid Sync: Generated ${session.durationLabel} sleep session for $targetStr from OS inactivity.',
      );

      return session;
    } catch (e) {
      return null;
    }
  }

  /// Called from WorkManager background recovery job to close orphaned sessions.
  static Future<void> closeOrphanedSessionIfStale(
      SleepRepository repository) async {
    try {
      await repository.init();
      final ongoing = await repository.getOngoingSession();
      if (ongoing == null) return;

      final now = DateTime.now();
      final elapsedMins =
          (now.millisecondsSinceEpoch - ongoing.sleepStartMs) ~/ 60000;

      // 1. Safety limit check: exceeded 14 hours
      if (elapsedMins >= maxSessionSafetyMinutes) {
        final closeAtMs =
            ongoing.sleepStartMs + (maxSessionSafetyMinutes * 60 * 1000);
        await repository.endAutoSession(
          id: ongoing.id,
          wakeTimeMs: closeAtMs,
          sleepStartMs: ongoing.sleepStartMs,
          closureReason: ClosureReason.safetyTimeout,
        );
        await _log(
          'WorkManager: stale session ${ongoing.id} auto-closed at ${maxSessionSafetyMinutes}min (SAFETY_TIMEOUT).',
        );
        return;
      }

      // 2. Abandoned session check: no epochs written for >45 minutes
      final recentEpochs = await repository.getEpochsForSession(ongoing.id);
      if (recentEpochs.isNotEmpty) {
        final lastEpoch = recentEpochs.last;
        final timeSinceLastEpochMins =
            (now.millisecondsSinceEpoch - lastEpoch.endTimeMs) ~/ 60000;
        if (timeSinceLastEpochMins >= 45) {
          await repository.endAutoSession(
            id: ongoing.id,
            wakeTimeMs: lastEpoch.endTimeMs,
            sleepStartMs: ongoing.sleepStartMs,
            closureReason: ClosureReason.recovery,
          );
          await _log(
            'WorkManager: abandoned session ${ongoing.id} recovered after ${timeSinceLastEpochMins}m gap at last epoch timestamp (RECOVERY).',
          );
        }
      }
    } catch (_) {
      // Recovery errors must never crash the WorkManager task.
    }
  }

  /// Reconstructs and persists any missing sleep sessions from diagnostic logs
  /// in SharedPreferences if SQLite was re-initialized or missed the write.
  static Future<void> recoverFromDiagnosticLogsIfEmpty(SleepRepository repository) async {
    try {
      await SleepDetectionLogger().init();
      final logs = SleepDetectionLogger().logs;
      if (logs.isEmpty) return;

      int? currentStartMs;
      int currentConfidence = 90;

      // Diagnostic logs are stored newest-first. Reverse to process chronologically.
      for (final entry in logs.reversed) {
        final event = entry.event;
        final ts = entry.timestamp.millisecondsSinceEpoch;
        if (ts <= 0) continue;

        if (event.contains('AWAKE → POSSIBLESLEEP') ||
            (event.contains('POSSIBLESLEEP') && currentStartMs == null)) {
          currentStartMs ??= ts;
          if (entry.confidenceScore != null && entry.confidenceScore! > 0) {
            currentConfidence = entry.confidenceScore!;
          }
        } else if (event.contains('Screen turned ON') ||
            event.contains('POSSIBLEWAKE → AWAKE') ||
            event.contains('SLEEPING → AWAKE')) {
          if (currentStartMs != null && ts > currentStartMs) {
            final durMins = ((ts - currentStartMs) / 60000).round();
            if (durMins >= 45 && durMins <= 840) {
              final existing = await repository.getRecentSessions(days: 2);
              final isDuplicate = existing.any(
                (s) => (s.sleepStartMs - currentStartMs!).abs() < 20 * 60 * 1000,
              );
              if (!isDuplicate) {
                final recovered = SleepSession(
                  id: 'auto_$currentStartMs',
                  sleepStartMs: currentStartMs,
                  wakeTimeMs: ts,
                  durationMinutes: durMins,
                  confidenceScore: currentConfidence,
                  createdAt: currentStartMs,
                  isAutomatic: true,
                  isNap:
                      durMins < 180 &&
                      DateTime.fromMillisecondsSinceEpoch(currentStartMs).hour >= 6,
                  closureReason: ClosureReason.normalWake,
                );
                await repository.saveAutoSession(recovered);
                await _log(
                  'Recovered session ${recovered.id} (${durMins}m, bedtime=${DateTime.fromMillisecondsSinceEpoch(currentStartMs)}) from diagnostic logs.',
                );
              }
            }
            currentStartMs = null;
          }
        }
      }
    } catch (_) {}
  }

  // ── Logging ────────────────────────────────────────────────────────────────

  static Future<void> _log(String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_recoveryLogPrefKey) ?? [];
      final entry =
          '[${DateTime.now().toIso8601String()}] $message';
      final updated = [entry, ...existing].take(20).toList();
      await prefs.setStringList(_recoveryLogPrefKey, updated);
    } catch (_) {}
  }

  /// Returns the last N recovery log entries for the diagnostics page.
  static Future<List<String>> getRecoveryLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_recoveryLogPrefKey) ?? [];
    } catch (_) {
      return [];
    }
  }
}
