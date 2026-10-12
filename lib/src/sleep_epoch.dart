/// Sleep Epoch Model
///
/// Represents a single 60-second window of aggregated sensor data captured
/// during an auto-detected sleep session.
///
/// Epochs are persisted in the `sleep_epochs` SQLite table.
/// The stored data is used by [SleepAnalysisEngine] to compute session-level
/// metrics: awakening count, sleep efficiency, longest sleep stretch, etc.
///
/// Nullability Policy:
///   If a sensor or signal was not actively sampled during this epoch, its field
///   is null (e.g. `ambientLux == null`), NOT a fake 0.0 or false constant.
library;

// ─── Enums ────────────────────────────────────────────────────────────────────

/// Qualitative reliability score of the sensor readings for this 60-second window.
enum DataQuality {
  high,
  medium,
  low,
  missing;

  String get label {
    switch (this) {
      case DataQuality.high:
        return 'High';
      case DataQuality.medium:
        return 'Medium';
      case DataQuality.low:
        return 'Low';
      case DataQuality.missing:
        return 'Missing';
    }
  }

  static DataQuality fromString(String? val) {
    if (val == null) return DataQuality.high;
    switch (val.toLowerCase()) {
      case 'high':
        return DataQuality.high;
      case 'medium':
        return DataQuality.medium;
      case 'low':
        return DataQuality.low;
      case 'missing':
        return DataQuality.missing;
      default:
        return DataQuality.high;
    }
  }
}

// ─── SleepEpoch ──────────────────────────────────────────────────────────────

/// One 60-second monitoring window within a [SleepSession].
class SleepEpoch {
  /// Unique identifier: `epoch_<sessionId>_<startTimeMs>`.
  final String id;

  /// Parent session identifier (references `sleep_auto_sessions.id`).
  final String sessionId;

  /// Epoch window start (epoch milliseconds).
  final int startTimeMs;

  /// Epoch window end (epoch milliseconds).
  final int endTimeMs;

  // ── Motion signals ─────────────────────────────────────────────────────────

  /// Combined accelerometer movement score (0–100).
  /// 0 = completely still, 100 = highly active. Null if missing/unmeasured.
  final int? movementScore;

  /// Standard deviation of raw magnitude readings in burst window.
  final double? movementVariance;

  /// Linear regression slope of rolling motion window.
  final double? movementTrend;

  /// Gyroscope rotation score (0–100). Null if gyroscope not sampled.
  final int? rotationScore;

  // ── Screen & interaction signals ───────────────────────────────────────────

  /// Seconds the screen was ON during this epoch (0–60).
  final int screenOnDurationSecs;

  /// Count of screen activation (turn-on) events this epoch.
  final int screenActivationCount;

  /// Number of device unlock events this epoch. Null if unmeasured.
  final int? unlockCount;

  /// User interaction / touch event count this epoch. Null if unmeasured.
  final int? interactionCount;

  // ── Environment signals ────────────────────────────────────────────────────

  /// Ambient light in lux at the end of this epoch. Null if unmeasured.
  final double? ambientLux;

  /// True if proximity obstruction reported. Null if unmeasured.
  final bool? proximityNear;

  /// True if the device was charging during this epoch.
  final bool isCharging;

  /// Battery level 0–100. Null if unmeasured.
  final int? batteryLevel;

  /// Activity recognition state (e.g. 'still', 'walking', 'unknown').
  final String? activityState;

  /// Data quality rating for this epoch.
  final DataQuality dataQuality;

  // ─────────────────────────────────────────────────────────────────────────

  const SleepEpoch({
    required this.id,
    required this.sessionId,
    required this.startTimeMs,
    required this.endTimeMs,
    this.movementScore = 50,
    this.movementVariance,
    this.movementTrend,
    this.rotationScore,
    this.screenOnDurationSecs = 0,
    this.screenActivationCount = 0,
    this.unlockCount,
    this.interactionCount,
    this.ambientLux,
    this.proximityNear,
    this.isCharging = false,
    this.batteryLevel,
    this.activityState,
    this.dataQuality = DataQuality.high,
  });

  /// Duration of this epoch in seconds.
  int get durationSecs =>
      ((endTimeMs - startTimeMs) / 1000).round().clamp(0, 120);

  /// Duration as a [Duration] object.
  Duration get duration => Duration(milliseconds: endTimeMs - startTimeMs);

  /// True if this epoch represents an awakening during an otherwise sleep session.
  ///
  /// Criteria (conservative to avoid false awakenings from brief notification glances):
  ///   - Screen was on for more than 20 seconds, OR
  ///   - Confirmed unlock or interactive touches, OR
  ///   - Walking activity detected by Activity Recognition.
  bool get isAwakening =>
      screenOnDurationSecs > 20 ||
      (unlockCount != null && unlockCount! > 0) ||
      (interactionCount != null && interactionCount! > 0) ||
      activityState == 'walking';

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Serialise to a map for SQLite insertion.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sessionId': sessionId,
      'startTimeMs': startTimeMs,
      'endTimeMs': endTimeMs,
      'movementScore': movementScore,
      'movementVariance': movementVariance,
      'movementTrend': movementTrend,
      'rotationScore': rotationScore,
      'screenOnDurationSecs': screenOnDurationSecs,
      'screenActivationCount': screenActivationCount,
      'unlockCount': unlockCount,
      'interactionCount': interactionCount,
      'ambientLux': ambientLux,
      'proximityNear': proximityNear == null
          ? null
          : (proximityNear! ? 1 : 0),
      'isCharging': isCharging ? 1 : 0,
      'batteryLevel': batteryLevel,
      'activityState': activityState,
      'dataQuality': dataQuality.name,
      // Backward compatibility schema columns:
      'stage': 'awake',
      'confidence': 50,
    };
  }

  /// Deserialise from a raw SQLite row.
  factory SleepEpoch.fromMap(Map<String, dynamic> map) {
    return SleepEpoch(
      id: map['id'] as String,
      sessionId: map['sessionId'] as String,
      startTimeMs: map['startTimeMs'] as int,
      endTimeMs: map['endTimeMs'] as int,
      movementScore: map['movementScore'] as int?,
      movementVariance: (map['movementVariance'] as num?)?.toDouble(),
      movementTrend: (map['movementTrend'] as num?)?.toDouble(),
      rotationScore: map['rotationScore'] as int?,
      screenOnDurationSecs: map['screenOnDurationSecs'] as int? ?? 0,
      screenActivationCount: map['screenActivationCount'] as int? ?? 0,
      unlockCount: map['unlockCount'] as int?,
      interactionCount: map['interactionCount'] as int?,
      ambientLux: (map['ambientLux'] as num?)?.toDouble(),
      proximityNear: map['proximityNear'] == null
          ? null
          : (map['proximityNear'] as int) == 1,
      isCharging: (map['isCharging'] as int? ?? 0) == 1,
      batteryLevel: map['batteryLevel'] as int?,
      activityState: map['activityState'] as String?,
      dataQuality: DataQuality.fromString(map['dataQuality'] as String?),
    );
  }
}
