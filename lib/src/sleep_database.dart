/// Database layer for automatically-detected sleep sessions and per-minute epochs.
///
/// Tables managed:
///   - `sleep_auto_sessions`  — session start/end boundaries, closureReason, confidence.
///   - `sleep_epochs`         — per-minute sensor snapshots with nullable signal fields
///                              and data quality classification.
///
/// Manual sleep entries stay in the host app's own storage; the
/// [SleepRepository] merges session sources at the query layer.
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'sleep_epoch.dart';
import 'sleep_session.dart';

class SleepDatabase {
  static const String epochTableName = 'sleep_epochs';
  static const String tableName = 'sleep_auto_sessions';
  static const String defaultFileName = 'sleep_sense.db';

  static Future<Database>? _defaultDb;

  /// The package's own database, opened once per isolate. sqflite shares the
  /// underlying file between the UI and background isolates.
  static Future<Database> openDefault() => _defaultDb ??= _openDefault();

  static Future<Database> _openDefault() async {
    final path = p.join(await getDatabasesPath(), defaultFileName);
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await createTable(db);
        await createEpochTable(db);
      },
    );
  }

  /// Creates the sessions table. Call from your own database's `onCreate` /
  /// `onUpgrade` when passing it to [SleepRepository].
  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        id              TEXT PRIMARY KEY,
        sleepStartMs    INTEGER NOT NULL,
        wakeTimeMs      INTEGER,
        durationMinutes INTEGER NOT NULL DEFAULT 0,
        confidenceScore INTEGER NOT NULL DEFAULT 0,
        createdAt       INTEGER NOT NULL,
        isNap           INTEGER NOT NULL DEFAULT 0,
        trackingMode    TEXT NOT NULL DEFAULT 'hybrid',
        closureReason   TEXT NOT NULL DEFAULT 'normalWake',
        source          TEXT NOT NULL DEFAULT 'phone_heuristic'
      )
    ''');

    // Index on sleepStartMs for fast date-range queries.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sleep_auto_start
      ON $tableName (sleepStartMs)
    ''');
  }

  /// Creates the `sleep_epochs` table.
  static Future<void> createEpochTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $epochTableName (
        id                    TEXT PRIMARY KEY,
        sessionId             TEXT NOT NULL,
        startTimeMs           INTEGER NOT NULL,
        endTimeMs             INTEGER NOT NULL,
        movementScore         INTEGER,
        movementVariance      REAL,
        movementTrend         REAL,
        rotationScore         INTEGER,
        screenOnDurationSecs  INTEGER NOT NULL DEFAULT 0,
        screenActivationCount INTEGER NOT NULL DEFAULT 0,
        unlockCount           INTEGER,
        interactionCount      INTEGER,
        ambientLux            REAL,
        proximityNear         INTEGER,
        isCharging            INTEGER NOT NULL DEFAULT 0,
        batteryLevel          INTEGER,
        activityState         TEXT,
        dataQuality           TEXT NOT NULL DEFAULT 'high',
        stage                 TEXT DEFAULT 'awake',
        confidence            INTEGER DEFAULT 50
      )
    ''');

    // Composite index: retrieve all epochs for a session ordered by time.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_epoch_session
      ON $epochTableName (sessionId, startTimeMs)
    ''');
  }

  // ─── CRUD Operations ────────────────────────────────────────────────────

  final Database _db;
  SleepDatabase(this._db);

  Future<void> upsert(Map<String, dynamic> row) async {
    await _db.insert(
      tableName,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Upserts many session rows in a single transaction — used when syncing
  /// a batch of Health Connect records at once instead of one write per row.
  Future<void> upsertMany(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final batch = _db.batch();
    for (final row in rows) {
      batch.insert(tableName, row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateWake({
    required String id,
    required int wakeTimeMs,
    required int durationMinutes,
    ClosureReason? closureReason,
  }) async {
    final values = <String, dynamic>{
      'wakeTimeMs': wakeTimeMs,
      'durationMinutes': durationMinutes,
    };
    if (closureReason != null) {
      values['closureReason'] = closureReason.name;
    }
    await _db.update(
      tableName,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Updates both the sleep start and wake time of an existing session.
  Future<void> updateSession({
    required String id,
    required int sleepStartMs,
    required int wakeTimeMs,
    required int durationMinutes,
    ClosureReason? closureReason,
  }) async {
    final values = <String, dynamic>{
      'sleepStartMs': sleepStartMs,
      'wakeTimeMs': wakeTimeMs,
      'durationMinutes': durationMinutes,
    };
    if (closureReason != null) {
      values['closureReason'] = closureReason.name;
    }
    await _db.update(
      tableName,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Fetches sessions whose sleep start falls within [fromMs] to [toMs].
  Future<List<Map<String, dynamic>>> getSessionsInRange({
    required int fromMs,
    required int toMs,
  }) async {
    return _db.query(
      tableName,
      where: 'sleepStartMs >= ? AND sleepStartMs <= ?',
      whereArgs: [fromMs, toMs],
      orderBy: 'sleepStartMs DESC',
    );
  }

  /// Fetches all sessions, ordered newest first. Used for history view.
  Future<List<Map<String, dynamic>>> getAllSessions() async {
    return _db.query(tableName, orderBy: 'sleepStartMs DESC');
  }

  /// Returns the currently ongoing session (wakeTimeMs IS NULL), if any.
  Future<Map<String, dynamic>?> getOngoingSession() async {
    final rows = await _db.query(
      tableName,
      where: 'wakeTimeMs IS NULL',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> getSessionById(String id) async {
    final rows = await _db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> delete(String id) async {
    await _db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteOldDummies() async {
    await _db.delete(tableName, where: "id LIKE 'auto_dummy_%' OR id LIKE 'auto_sim_%' OR id = 'auto_1787946869537'");
  }

  // ── Epoch CRUD ────────────────────────────────────────────────────────────

  /// Inserts or replaces a single epoch row.
  Future<void> insertEpoch(SleepEpoch epoch) async {
    await _db.insert(
      epochTableName,
      epoch.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Inserts a batch of epochs within a single transaction.
  Future<void> insertEpochs(List<SleepEpoch> epochs) async {
    if (epochs.isEmpty) return;
    final batch = _db.batch();
    for (final epoch in epochs) {
      batch.insert(
        epochTableName,
        epoch.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Returns all epochs for [sessionId], ordered chronologically.
  Future<List<SleepEpoch>> getEpochsForSession(String sessionId) async {
    final rows = await _db.query(
      epochTableName,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'startTimeMs ASC',
    );
    return rows.map(SleepEpoch.fromMap).toList();
  }

  /// Returns the most recent epochs recorded across all sessions.
  Future<List<SleepEpoch>> getRecentEpochs({int limit = 300}) async {
    final rows = await _db.query(
      epochTableName,
      orderBy: 'startTimeMs DESC',
      limit: limit,
    );
    return rows.map(SleepEpoch.fromMap).toList();
  }

  /// Deletes all epochs belonging to [sessionId].
  Future<void> deleteEpochsForSession(String sessionId) async {
    await _db.delete(
      epochTableName,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
  }

  // ── Diagnostic Helpers ───────────────────────────────────────────────────

  /// Returns total count of sessions in `sleep_auto_sessions`.
  Future<int> getSessionCount() async {
    final res = await _db.rawQuery('SELECT COUNT(*) as count FROM $tableName');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Returns total count of epochs in `sleep_epochs`.
  Future<int> getEpochCount() async {
    final res = await _db.rawQuery('SELECT COUNT(*) as count FROM $epochTableName');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Returns raw SQLite session maps for diagnostics inspection.
  Future<List<Map<String, dynamic>>> getRawSessions({int limit = 50}) async {
    return _db.query(
      tableName,
      orderBy: 'sleepStartMs DESC',
      limit: limit,
    );
  }

  /// Returns raw SQLite epoch maps for diagnostics inspection.
  Future<List<Map<String, dynamic>>> getRawEpochsForSession(String sessionId) async {
    return _db.query(
      epochTableName,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'startTimeMs ASC',
    );
  }

  /// Returns raw recent epochs across all sessions for diagnostics inspection.
  Future<List<Map<String, dynamic>>> getRawRecentEpochs({int limit = 100}) async {
    return _db.query(
      epochTableName,
      orderBy: 'startTimeMs DESC',
      limit: limit,
    );
  }
}
