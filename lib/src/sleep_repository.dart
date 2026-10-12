/// Repository that merges auto-detected sessions and manual sleep entries
/// into a single unified [SleepSession] stream for the UI.
///
/// Architecture note: The repository pattern isolates the UI from data source
/// details. Whether a session comes from `sleep_auto_sessions` (automatic)
/// or from the host app's own manual log (see [ManualSleepSource]), the
/// consumer gets identical [SleepSession] objects. Only [sourceBadge] differs.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'sleep_database.dart';
import 'sleep_epoch.dart';
import 'sleep_session.dart';

/// Supplies sleep the user logged by hand, kept in the host app's own
/// storage. Build each entry with [SleepSession.fromManualEntry]. Manual
/// entries take precedence over auto-detected sessions for the same night.
typedef ManualSleepSource = Future<List<SleepSession>> Function();

class SleepRepository {
  final Future<Database> Function() _openDatabase;
  final ManualSleepSource? _manualSessions;
  late SleepDatabase _sleepDb;
  bool _initialized = false;

  /// Uses the package's own database file unless [database] is given — pass
  /// one to keep the sleep tables in your app's database. Its `onCreate` /
  /// `onUpgrade` must then call [SleepDatabase.createTable] and
  /// [SleepDatabase.createEpochTable].
  SleepRepository({
    Future<Database> Function()? database,
    ManualSleepSource? manualSessions,
  })  : _openDatabase = database ?? SleepDatabase.openDefault,
        _manualSessions = manualSessions ?? defaultManualSessions;

  /// Manual source for repositories created without one, including the ones
  /// the package creates internally. Set by `AutoSleepTracker.initialize`.
  static ManualSleepSource? defaultManualSessions;

  /// Must be called once before using any query methods.
  Future<void> init() async {
    if (_initialized) return;
    final db = await _openDatabase();
    _sleepDb = SleepDatabase(db);
    _initialized = true;
  }

  // ─── Auto Session Management ─────────────────────────────────────────────

  /// Persists a new auto-detected session start. Returns the generated ID.
  Future<String> startAutoSession({
    required int sleepStartMs,
    required int confidenceScore,
    bool isNap = false,
    SleepTrackingMode trackingMode = SleepTrackingMode.hybrid,
  }) async {
    await init();
    final id = 'auto_${DateTime.now().millisecondsSinceEpoch}';
    await _sleepDb.upsert({
      'id': id,
      'sleepStartMs': sleepStartMs,
      'wakeTimeMs': null,
      'durationMinutes': 0,
      'confidenceScore': confidenceScore,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'isNap': isNap ? 1 : 0,
      'trackingMode': trackingMode.name,
      'closureReason': ClosureReason.unknown.name,
    });
    return id;
  }

  /// Directly inserts or updates a full auto session (any source).
  Future<void> saveAutoSession(SleepSession session) async {
    await init();
    await _sleepDb.upsert(session.toAutoMap());
  }

  /// Upserts a batch of Health Connect-sourced sessions in one transaction.
  /// Each session's id is derived from the Health Connect record's own UUID
  /// (see [SleepSession.fromHealthConnect]), so re-syncing the same period
  /// replaces the same rows rather than creating duplicates.
  Future<void> saveHealthConnectSessions(List<SleepSession> sessions) async {
    if (sessions.isEmpty) return;
    await init();
    await _sleepDb.upsertMany(sessions.map((s) => s.toAutoMap()).toList());
  }

  /// Deletes any dummy/seeded sessions that were previously inserted for demo
  /// purposes. Called once on app init to clean up stale data.
  Future<void> purgeDummyAutoSessions() async {
    await init();
    await _sleepDb.deleteOldDummies();
    final prefs = await SharedPreferences.getInstance();
    // Clear all old seed flags so there's no stale state.
    await prefs.remove('has_seeded_sleep_dummies_v2');
    await prefs.remove('has_seeded_sleep_dummies_v3');
  }

  /// Updates the wake time on an ongoing session. Computes duration automatically.
  Future<void> endAutoSession({
    required String id,
    required int wakeTimeMs,
    required int sleepStartMs,
    ClosureReason closureReason = ClosureReason.normalWake,
  }) async {
    await init();
    final durationMinutes = ((wakeTimeMs - sleepStartMs) / 60000).round().clamp(0, 1440);
    await _sleepDb.updateWake(
      id: id,
      wakeTimeMs: wakeTimeMs,
      durationMinutes: durationMinutes,
      closureReason: closureReason,
    );
  }

  /// Updates sleep start and/or wake time on an existing auto session.
  Future<void> updateAutoSession({
    required String id,
    required int sleepStartMs,
    required int wakeTimeMs,
    ClosureReason? closureReason,
  }) async {
    await init();
    final durationMinutes = ((wakeTimeMs - sleepStartMs) / 60000).round().clamp(0, 1440);
    await _sleepDb.updateSession(
      id: id,
      sleepStartMs: sleepStartMs,
      wakeTimeMs: wakeTimeMs,
      durationMinutes: durationMinutes,
      closureReason: closureReason,
    );
  }

  /// Permanently deletes an auto-detected session by id.
  Future<void> deleteAutoSession(String id) async {
    await init();
    await _sleepDb.delete(id);
  }

  /// Returns the currently ongoing auto session, or null.
  Future<SleepSession?> getOngoingSession() async {
    await init();
    final row = await _sleepDb.getOngoingSession();
    if (row == null) return null;
    return SleepSession.fromAutoMap(row);
  }

  // ─── Unified Queries ─────────────────────────────────────────────────────

  /// Returns all sessions (auto + manual) in the last [days] days,
  /// sorted newest first with intelligent deduplication (manual entries take precedence
  /// when overlapping with auto-detected sessions for the same night).
  Future<List<SleepSession>> getRecentSessions({
    int days = 30,
    DateTime? anchorDate,
  }) async {
    await init();
    final now = anchorDate ?? DateTime.now();
    final fromMs = now.subtract(Duration(days: days)).millisecondsSinceEpoch;
    final toMs = now.add(const Duration(days: 1)).millisecondsSinceEpoch;

    // Fetch auto sessions.
    final autoRows = await _sleepDb.getSessionsInRange(fromMs: fromMs, toMs: toMs);
    final autoSessions = autoRows.map(SleepSession.fromAutoMap).toList();

    // Fetch manual sleep entries from the host app, if it keeps any.
    final manualSessions = await _loadManualSessions(fromMs: fromMs);

    // A manual log is the user's own account of that day's sleep, so it
    // replaces every auto session attributed to the same day or overlapping
    // it in time.
    final manualDates = manualSessions.map((m) => m.canonicalDateString).toSet();
    final autoWithoutManual = autoSessions.where((auto) {
      if (manualDates.contains(auto.canonicalDateString)) return false;
      return !manualSessions.any((manual) => _overlaps(auto, manual));
    }).toList();

    final all = [...manualSessions, ...dedupeOverlappingAuto(autoWithoutManual)]
      ..sort((a, b) => b.sleepStartMs.compareTo(a.sleepStartMs));
    return all;
  }

  /// The same night can be recorded several times: Health Connect plus the
  /// phone heuristic, the live detector plus the OS-inactivity sync, or a
  /// recovered session. Keeping all of them double counts the sleep, so of
  /// any sessions that overlap in time only the most trustworthy survives:
  /// Health Connect over phone heuristics, completed over ongoing, then the
  /// longer session.
  @visibleForTesting
  static List<SleepSession> dedupeOverlappingAuto(List<SleepSession> sessions) {
    final ranked = [...sessions]
      ..sort((a, b) {
        if (a.isFromHealthConnect != b.isFromHealthConnect) {
          return a.isFromHealthConnect ? -1 : 1;
        }
        if (a.isOngoing != b.isOngoing) return a.isOngoing ? 1 : -1;
        return b.durationMinutes.compareTo(a.durationMinutes);
      });
    final kept = <SleepSession>[];
    for (final s in ranked) {
      if (!kept.any((k) => _overlaps(k, s))) kept.add(s);
    }
    return kept;
  }

  static bool _overlaps(SleepSession a, SleepSession b) =>
      a.sleepStartMs < _endMs(b) && b.sleepStartMs < _endMs(a);

  /// Ongoing sessions run until now, capped at the 14h safety limit so a
  /// stale orphaned session can't swallow every later night.
  static int _endMs(SleepSession s) {
    if (s.wakeTimeMs != null) return s.wakeTimeMs!;
    final capMs = s.sleepStartMs + SleepSession.maxSessionDurationMinutes * 60000;
    return math.min(DateTime.now().millisecondsSinceEpoch, capMs);
  }

  /// Returns sessions for exactly 7 days ending at [anchorDate], one slot per day.
  /// Uses [matchesDate] for accurate midnight-crossing and wake-up attribution.
  Future<List<SleepSession?>> getWeeklySessions({DateTime? anchorDate}) async {
    final baseDate = anchorDate ?? DateTime.now();
    final sessions = await getRecentSessions(days: 14, anchorDate: baseDate);

    return List.generate(7, (i) {
      final targetDay = baseDate.subtract(Duration(days: 6 - i));
      final forDay = sessions.where((s) => s.matchesDate(targetDay)).toList();

      if (forDay.isEmpty) return null;

      // Prefer manual if user logged for that day; otherwise Health Connect
      // over phone-heuristic auto detection; then longest session.
      forDay.sort((a, b) {
        if (a.isAutomatic != b.isAutomatic) return a.isAutomatic ? 1 : -1;
        if (a.isFromHealthConnect != b.isFromHealthConnect) {
          return a.isFromHealthConnect ? -1 : 1;
        }
        return b.durationMinutes.compareTo(a.durationMinutes);
      });
      return forDay.first;
    });
  }

  /// Returns sessions for the last [months] months, grouped by week for chart display.
  Future<double> getMonthlyAverageDurationHours({int months = 1}) async {
    final sessions = await getRecentSessions(days: months * 30);
    if (sessions.isEmpty) return 0.0;
    final completedSessions = sessions.where((s) => !s.isOngoing).toList();
    if (completedSessions.isEmpty) return 0.0;
    final totalMins = completedSessions.fold(0, (sum, s) => sum + s.durationMinutes);
    return double.parse((totalMins / completedSessions.length / 60.0).toStringAsFixed(1));
  }

  /// Sleep consistency score (0–100). Measures how regular the bedtime is.
  ///
  /// Formula: 100 - (stdDev of sleep start hour × 10), clamped 0–100.
  /// A consistent bedtime (stdDev ≈ 0) scores 100; a 1-hour stdDev scores 90.
  ///
  /// ⚠️ Simplification: This only considers bedtime regularity, not sleep duration
  /// regularity or chronotype alignment. Clinical consistency metrics are more complex.
  Future<int> getSleepConsistencyScore() async {
    final sessions = await getRecentSessions(days: 28); // 4-week window
    if (sessions.length < 3) return 0; // Not enough data.

    // Extract fractional hours of sleep start (e.g. 23.5 = 11:30 PM).
    final hours = sessions.map((s) {
      final dt = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
      // Normalize to a 24-hour value, treating hours 0–9 as 24–33
      // so that midnight-crossing doesn't skew the stdDev.
      final h = dt.hour + dt.minute / 60.0;
      return h < 10 ? h + 24 : h;
    }).toList();

    final mean = hours.reduce((a, b) => a + b) / hours.length;
    final variance = hours.map((h) => math.pow(h - mean, 2)).reduce((a, b) => a + b) / hours.length;
    final stdDev = math.sqrt(variance);

    return (100 - (stdDev * 10)).clamp(0, 100).round();
  }

  // ─── Export Helpers ───────────────────────────────────────────────────────

  /// Exports all sessions (auto + manual) from the last [days] days as a CSV string.
  /// Columns: Type, Date, Bedtime, WakeTime, DurationMinutes, DurationHours, Confidence, Notes
  Future<String> exportSessionsToCSV({int days = 365}) async {
    final sessions = await getRecentSessions(days: days);
    final dtFmt = DateFormat('yyyy-MM-dd');
    final tmFmt = DateFormat('HH:mm');
    final buf = StringBuffer();
    buf.writeln('Type,Date,Bedtime,WakeTime,DurationMinutes,DurationHours,ConfidenceScore,IsNap,Notes');
    for (final s in sessions) {
      final start = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
      final wake = s.wakeTimeMs != null
          ? DateTime.fromMillisecondsSinceEpoch(s.wakeTimeMs!)
          : null;
      final type = s.isAutomatic ? 'Auto' : 'Manual';
      final date = dtFmt.format(start);
      final bedtime = tmFmt.format(start);
      final waketime = wake != null ? tmFmt.format(wake) : '';
      final notes = s.notes.replaceAll(',', ';').replaceAll('\n', ' ');
      buf.writeln('$type,$date,$bedtime,$waketime,${s.durationMinutes},${s.durationHours.toStringAsFixed(2)},${s.confidenceScore},${s.isNap ? 1 : 0},$notes');
    }
    return buf.toString();
  }

  /// Exports all sessions (auto + manual) from the last [days] days as a JSON string.
  Future<String> exportSessionsToJSON({int days = 365}) async {
    final sessions = await getRecentSessions(days: days);
    final dtFmt = DateFormat('yyyy-MM-dd');
    final tmFmt = DateFormat('HH:mm');
    final list = sessions.map((s) {
      final start = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
      final wake = s.wakeTimeMs != null
          ? DateTime.fromMillisecondsSinceEpoch(s.wakeTimeMs!)
          : null;
      return {
        'id': s.id,
        'type': s.isAutomatic ? 'auto' : 'manual',
        'date': dtFmt.format(start),
        'bedtime': tmFmt.format(start),
        'wakeTime': wake != null ? tmFmt.format(wake) : null,
        'durationMinutes': s.durationMinutes,
        'durationHours': double.parse(s.durationHours.toStringAsFixed(2)),
        'confidenceScore': s.confidenceScore,
        'isNap': s.isNap,
        'qualityRating': s.manualQualityRating,
        'factors': s.factors,
        'notes': s.notes,
      };
    }).toList();
    return const JsonEncoder.withIndent('  ').convert({'sleepSessions': list});
  }

  // ─── Private Helpers ─────────────────────────────────────────────────────

  Future<List<SleepSession>> _loadManualSessions({required int fromMs}) async {
    final source = _manualSessions;
    if (source == null) return const [];
    try {
      final sessions = await source();
      return sessions.where((s) => s.sleepStartMs >= fromMs).toList();
    } catch (_) {
      // A failing host source must not hide the auto-detected history.
      return const [];
    }
  }

  /// Fetches a single session by its unique ID.
  Future<SleepSession?> getSessionById(String id) async {
    await init();
    final row = await _sleepDb.getSessionById(id);
    return row != null ? SleepSession.fromMap(row) : null;
  }

  // ─── Epoch Methods ───────────────────────────────────────────────

  /// Inserts or updates a single 60-second epoch into `sleep_epochs`.
  Future<void> saveEpoch(SleepEpoch epoch) async {
    await init();
    await _sleepDb.insertEpoch(epoch);
  }

  /// Inserts or updates a batch of epochs in a single transaction.
  Future<void> saveEpochs(List<SleepEpoch> epochs) async {
    await init();
    await _sleepDb.insertEpochs(epochs);
  }

  /// Returns all epochs for [sessionId] ordered chronologically.
  /// Returns an empty list if the session has no epoch data (e.g., manual entries).
  Future<List<SleepEpoch>> getEpochsForSession(String sessionId) async {
    await init();
    return _sleepDb.getEpochsForSession(sessionId);
  }

  /// Returns the most recent epochs recorded across all sessions.
  Future<List<SleepEpoch>> getRecentEpochs({int limit = 300}) async {
    await init();
    return _sleepDb.getRecentEpochs(limit: limit);
  }

  /// Deletes all epoch rows associated with [sessionId].
  /// Call when deleting a sleep session to avoid orphaned rows.
  Future<void> deleteEpochsForSession(String sessionId) async {
    await init();
    await _sleepDb.deleteEpochsForSession(sessionId);
  }

  // ─── Auto Sessions Direct Access ─────────────────────────────────────────

  /// Fetches all automatically recorded sleep sessions from SQLite,
  /// ordered newest first without date filtering.
  Future<List<SleepSession>> getAllAutoSessions({int limit = 100}) async {
    await init();
    final rows = await _sleepDb.getAllSessions();
    final sessions = dedupeOverlappingAuto(rows.map(SleepSession.fromAutoMap).toList())
      ..sort((a, b) => b.sleepStartMs.compareTo(a.sleepStartMs));
    return sessions.take(limit).toList();
  }

  /// Total count of sessions in database.
  Future<int> getSessionCount() async {
    await init();
    return _sleepDb.getSessionCount();
  }

  /// Total count of epochs in database.
  Future<int> getEpochCount() async {
    await init();
    return _sleepDb.getEpochCount();
  }

  /// Raw session maps for developer inspection.
  Future<List<Map<String, dynamic>>> getRawSessions({int limit = 50}) async {
    await init();
    return _sleepDb.getRawSessions(limit: limit);
  }

  /// Raw epoch maps for developer inspection.
  Future<List<Map<String, dynamic>>> getRawEpochsForSession(String sessionId) async {
    await init();
    return _sleepDb.getRawEpochsForSession(sessionId);
  }

  /// Raw recent epochs for developer inspection.
  Future<List<Map<String, dynamic>>> getRawRecentEpochs({int limit = 100}) async {
    await init();
    return _sleepDb.getRawRecentEpochs(limit: limit);
  }
}
