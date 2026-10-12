import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sleep_state_machine.dart';

/// Represents a single log record captured during automatic sleep tracking.
class SleepLogEntry {
  final String id;
  final DateTime timestamp;
  final String level; // 'INFO', 'STATE', 'SENSOR', 'WARN'
  final String event;
  final int? confidenceScore;
  final double? motionMagnitude;
  final double? motionVariance;
  final double? rollingAverageMotion;
  final double? motionTrendSlope;
  final bool? isScreenOff;
  final bool? isCharging;
  final String? activity;
  final String? details;

  SleepLogEntry({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.event,
    this.confidenceScore,
    this.motionMagnitude,
    this.motionVariance,
    this.rollingAverageMotion,
    this.motionTrendSlope,
    this.isScreenOff,
    this.isCharging,
    this.activity,
    this.details,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'level': level,
        'event': event,
        'confidenceScore': confidenceScore,
        'motionMagnitude': motionMagnitude,
        'motionVariance': motionVariance,
        'rollingAverageMotion': rollingAverageMotion,
        'motionTrendSlope': motionTrendSlope,
        'isScreenOff': isScreenOff,
        'isCharging': isCharging,
        'activity': activity,
        'details': details,
      };

  factory SleepLogEntry.fromJson(Map<String, dynamic> json) => SleepLogEntry(
        id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch),
        level: json['level'] as String? ?? 'INFO',
        event: json['event'] as String? ?? '',
        confidenceScore: json['confidenceScore'] as int?,
        motionMagnitude: (json['motionMagnitude'] as num?)?.toDouble(),
        motionVariance: (json['motionVariance'] as num?)?.toDouble(),
        rollingAverageMotion: (json['rollingAverageMotion'] as num?)?.toDouble(),
        motionTrendSlope: (json['motionTrendSlope'] as num?)?.toDouble(),
        isScreenOff: json['isScreenOff'] as bool?,
        isCharging: json['isCharging'] as bool?,
        activity: json['activity'] as String?,
        details: json['details'] as String?,
      );
}

/// Service that maintains and persists real-time diagnostic logs
/// for automatic sleep tracking.
class SleepDetectionLogger {
  static final SleepDetectionLogger _instance = SleepDetectionLogger._internal();
  factory SleepDetectionLogger() => _instance;
  SleepDetectionLogger._internal();

  static const String _prefKey = 'sleep_auto_tracking_diagnostic_logs';
  static const int _maxInMemoryLogs = 200;
  static const int _maxPersistedLogs = 100;

  final List<SleepLogEntry> _logs = [];
  final ValueNotifier<List<SleepLogEntry>> logsNotifier = ValueNotifier<List<SleepLogEntry>>([]);

  List<SleepLogEntry> get logs => List.unmodifiable(_logs);

  bool _initialized = false;

  // Debounce timer: SENSOR-level logs (one per minute all night) no longer
  // trigger an immediate SharedPreferences write. We flush at most every
  // 5 minutes for SENSOR entries, but immediately for STATE/INFO/WARN events.
  // Without this, the XML serialisation overhead from prefs writes was
  // happening 480+ times per 8-hour night.
  Timer? _pendingSaveTimer;
  static const Duration _debounceDuration = Duration(minutes: 5);

  /// Loads persisted logs from SharedPreferences. No-ops after the first
  /// call — use [reload] to force a fresh read.
  Future<void> init() async {
    if (_initialized) return;
    await _loadFromPrefs();
    _initialized = true;
  }

  /// Forces a fresh read from SharedPreferences, overwriting in-memory state.
  ///
  /// The real overnight detection loop runs in a separate headless isolate
  /// (see `sleep_background_service.dart`), which has its own independent
  /// `SleepDetectionLogger` instance — Dart isolates don't share static
  /// state. This instance (e.g. the one backing the diagnostics page) only
  /// sees the background isolate's writes once they've been flushed to
  /// SharedPreferences and this is called again. Call it whenever the user
  /// wants an up-to-date view (pull-to-refresh, a visible refresh button, a
  /// periodic timer while a diagnostics screen is open).
  Future<void> reload() async {
    await _loadFromPrefs();
    _initialized = true;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Force-read the underlying platform storage rather than this
      // isolate's cached copy of it, so writes from the background
      // isolate's SharedPreferences instance become visible here.
      await prefs.reload();
      _logs.clear();

      // Check for clean JSON string first
      final jsonStr = prefs.getString(_prefKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        try {
          final list = jsonDecode(jsonStr) as List<dynamic>;
          for (final item in list) {
            try {
              final map = item is String ? jsonDecode(item) as Map<String, dynamic> : item as Map<String, dynamic>;
              _logs.add(SleepLogEntry.fromJson(map));
            } catch (_) {}
          }
        } catch (_) {}
      }

      // Fallback to legacy string list if json string was empty
      if (_logs.isEmpty) {
        final raw = prefs.getStringList(_prefKey) ?? [];
        for (final item in raw) {
          try {
            final map = jsonDecode(item) as Map<String, dynamic>;
            _logs.add(SleepLogEntry.fromJson(map));
          } catch (_) {}
        }
      }

      logsNotifier.value = List.unmodifiable(_logs);
    } catch (_) {
      // Leave whatever was already loaded in place.
    }
  }

  /// Logs a general event (lifecycle, user action, worker trigger).
  void logEvent(String event, {String level = 'INFO', String? details}) {
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: level,
      event: event,
      details: details,
    ));
  }

  void logStateTransition({
    required SleepState fromState,
    required SleepState toState,
    required int confidenceScore,
    required String reason,
  }) {
    final from = fromState.name.toUpperCase();
    final to = toState.name.toUpperCase();
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'STATE',
      event: 'STATE_CHANGED: $from → $to',
      confidenceScore: confidenceScore,
      details: 'Confidence: $confidenceScore% | Reason: $reason',
    ));
  }

  /// Logs SESSION_CREATED event.
  void logSessionCreated({
    required String sessionId,
    required DateTime onsetTime,
    int bufferedEpochs = 0,
  }) {
    final onsetStr = DateFormat('HH:mm:ss').format(onsetTime);
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'INFO',
      event: 'SESSION_CREATED',
      details: 'id=$sessionId onset=$onsetStr bufferedEpochs=$bufferedEpochs',
    ));
  }

  /// Logs EPOCH_SAVED event.
  void logEpochSaved({
    required String sessionId,
    required DateTime timestamp,
    required int movementScore,
    required String quality,
  }) {
    final tsStr = DateFormat('HH:mm:ss').format(timestamp);
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'SENSOR',
      event: 'EPOCH_SAVED',
      details: 'session=$sessionId timestamp=$tsStr mov=$movementScore quality=$quality',
    ));
  }

  /// Logs SESSION_FINALIZED event.
  void logSessionFinalized({
    required String sessionId,
    required String reason,
    required int durationMinutes,
  }) {
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'INFO',
      event: 'SESSION_FINALIZED',
      details: 'id=$sessionId reason=$reason duration=${durationMinutes}min',
    ));
  }

  /// Logs SESSION_RECOVERED event.
  void logSessionRecovered({
    required String sessionId,
    required String note,
  }) {
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'WARN',
      event: 'SESSION_RECOVERED',
      details: 'id=$sessionId note=$note',
    ));
  }

  /// Logs SESSION_ANALYZED event.
  void logSessionAnalyzed({
    required String sessionId,
    required int totalSleepMins,
    required double efficiency,
    required int sleepScore,
  }) {
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'INFO',
      event: 'ANALYSIS_COMPLETED',
      details: 'id=$sessionId sleep=${totalSleepMins}min efficiency=${efficiency.toStringAsFixed(1)}% score=$sleepScore',
    ));
  }

  /// Logs REPORT_GENERATED event.
  void logReportGenerated({required String sessionId}) {
    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: DateTime.now(),
      level: 'INFO',
      event: 'REPORT_GENERATED',
      details: 'id=$sessionId',
    ));
  }

  /// Logs a completed sensor evaluation snapshot.
  void logSensorSnapshot({
    required SensorSnapshot snapshot,
    required StateMachineResult result,
    required String currentStateName,
  }) {
    final motionStr = snapshot.motionMagnitude.toStringAsFixed(4);
    final varianceStr = snapshot.motionVariance.toStringAsFixed(4);
    final rollingStr = snapshot.rollingAverageMotion.toStringAsFixed(4);
    final slopeStr = snapshot.motionTrendSlope.toStringAsFixed(4);
    final screenStr = snapshot.isScreenOff ? 'Screen OFF' : 'Screen ON';
    final chargingStr = snapshot.isCharging ? 'Charging' : 'Battery';
    final arStr = snapshot.activityRecognition ?? 'unknown';

    final details =
        'State: ${currentStateName.toUpperCase()} | Score: ${result.confidenceScore}% | '
        'Motion: $motionStr g (var: $varianceStr g) | '
        'RollAvg: $rollingStr g (slope: $slopeStr) | '
        '$screenStr | $chargingStr | AR: $arStr\n'
        'Reason: ${result.debugReason ?? "N/A"}';

    _addEntry(SleepLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_logs.length}',
      timestamp: snapshot.timestamp,
      level: 'SENSOR',
      event: 'Eval: [$currentStateName] Score: ${result.confidenceScore}%',
      confidenceScore: result.confidenceScore,
      motionMagnitude: snapshot.motionMagnitude,
      motionVariance: snapshot.motionVariance,
      rollingAverageMotion: snapshot.rollingAverageMotion,
      motionTrendSlope: snapshot.motionTrendSlope,
      isScreenOff: snapshot.isScreenOff,
      isCharging: snapshot.isCharging,
      activity: snapshot.activityRecognition,
      details: details,
    ));
  }

  void _addEntry(SleepLogEntry entry) {
    _logs.insert(0, entry);
    if (_logs.length > _maxInMemoryLogs) {
      _logs.removeLast();
    }
    logsNotifier.value = List.unmodifiable(_logs);

    // Flush immediately for important events; debounce SENSOR-level ticker logs
    // to at most one write per 5 minutes. SENSOR logs fire every 60 seconds all
    // night — without this debounce, that was 480+ SharedPreferences XML writes
    // per 8-hour night, continuously waking the disk.
    final isCritical = entry.level != 'SENSOR';
    if (isCritical) {
      _pendingSaveTimer?.cancel();
      _pendingSaveTimer = null;
      _saveToPrefs();
    } else if (_pendingSaveTimer == null || !_pendingSaveTimer!.isActive) {
      _pendingSaveTimer = Timer(_debounceDuration, () {
        _pendingSaveTimer = null;
        _saveToPrefs();
      });
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toSave = _logs.take(_maxPersistedLogs).map((e) => e.toJson()).toList();
      await prefs.setString(_prefKey, jsonEncode(toSave));
    } catch (_) {}
  }

  /// Clears all logs from memory and storage.
  Future<void> clearLogs() async {
    _pendingSaveTimer?.cancel();
    _pendingSaveTimer = null;
    _logs.clear();
    logsNotifier.value = [];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  /// Exports logs as a clean, human-readable text report for debugging.
  String exportFormattedText() {
    if (_logs.isEmpty) return 'No auto-tracking diagnostic logs available.';
    final sb = StringBuffer();
    sb.writeln('=== Auto Sleep Tracker Diagnostic Logs ===');
    sb.writeln('Generated: ${DateTime.now().toIso8601String()}');
    sb.writeln('Total Log Entries: ${_logs.length}\n');

    for (final log in _logs) {
      final timeStr = log.timestamp.toIso8601String();
      sb.writeln('[$timeStr] [${log.level}] ${log.event}');
      if (log.details != null && log.details!.isNotEmpty) {
        sb.writeln('   Details: ${log.details}');
      }
      sb.writeln('');
    }
    return sb.toString();
  }
}
