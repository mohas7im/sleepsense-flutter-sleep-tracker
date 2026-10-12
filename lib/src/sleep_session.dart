/// Unified display model that represents a single sleep session,
/// regardless of whether it was recorded automatically (via sensor detection)
/// or entered manually by the user.
///
/// ⚠️ Simplification note: This is a motion-based detection model.
/// Duration and quality are inferred from accelerometer + screen state.
/// This is NOT HR/actigraphy-grade sleep staging (no REM/NREM breakdown).
library;

// ─── Enums ────────────────────────────────────────────────────────────────────

/// Tracking mode used to infer this sleep session.
enum SleepTrackingMode {
  hybrid,
  usageBased;

  String get label {
    switch (this) {
      case SleepTrackingMode.hybrid:
        return 'Hybrid Mode';
      case SleepTrackingMode.usageBased:
        return 'Battery Saver Mode';
    }
  }

  String get badgeLabel {
    switch (this) {
      case SleepTrackingMode.hybrid:
        return '⭐ Auto (Hybrid)';
      case SleepTrackingMode.usageBased:
        return '🔋 Auto (Battery Saver)';
    }
  }

  static SleepTrackingMode fromString(String? val) {
    if (val == null) return SleepTrackingMode.hybrid;
    switch (val.toLowerCase()) {
      case 'usagebased':
      case 'usage_based':
      case 'usage_stats':
      case 'usage':
      case 'batterysaver':
      case 'battery_saver':
        return SleepTrackingMode.usageBased;
      case 'hybrid':
      default:
        return SleepTrackingMode.hybrid;
    }
  }
}

/// Reason why a sleep session was closed.
enum ClosureReason {
  normalWake,
  safetyTimeout,
  batteryDied,
  serviceStopped,
  recovery,
  manualOverride,
  unknown;

  String get label {
    switch (this) {
      case ClosureReason.normalWake:
        return 'Normal Wake';
      case ClosureReason.safetyTimeout:
        return 'Safety Timeout (14h)';
      case ClosureReason.batteryDied:
        return 'Battery Died';
      case ClosureReason.serviceStopped:
        return 'Service Stopped';
      case ClosureReason.recovery:
        return 'Background Recovery';
      case ClosureReason.manualOverride:
        return 'Manual Override';
      case ClosureReason.unknown:
        return 'Unknown';
    }
  }

  static ClosureReason fromString(String? val) {
    if (val == null) return ClosureReason.unknown;
    switch (val.toLowerCase()) {
      case 'normalwake':
      case 'normal_wake':
        return ClosureReason.normalWake;
      case 'safetytimeout':
      case 'safety_timeout':
        return ClosureReason.safetyTimeout;
      case 'batterydied':
      case 'battery_died':
        return ClosureReason.batteryDied;
      case 'servicestopped':
      case 'service_stopped':
        return ClosureReason.serviceStopped;
      case 'recovery':
        return ClosureReason.recovery;
      case 'manualoverride':
      case 'manual_override':
        return ClosureReason.manualOverride;
      default:
        return ClosureReason.unknown;
    }
  }
}

/// Qualitative sensor detection confidence rating.
enum DetectionConfidence {
  high,
  medium,
  low;

  String get label {
    switch (this) {
      case DetectionConfidence.high:
        return 'High';
      case DetectionConfidence.medium:
        return 'Medium';
      case DetectionConfidence.low:
        return 'Low';
    }
  }

  static DetectionConfidence fromScore(int score) {
    if (score >= 75) return DetectionConfidence.high;
    if (score >= 50) return DetectionConfidence.medium;
    return DetectionConfidence.low;
  }
}

// ─── SleepSession ─────────────────────────────────────────────────────────────

class SleepSession {
  /// Maximum safety cutoff for a session (14 hours = 840 minutes).
  static const int maxSessionDurationMinutes = 14 * 60;

  /// Unique identifier. Auto sessions use UUID; manual sessions reuse
  /// the HealthSleepEntry.id.
  final String id;

  /// Epoch milliseconds when sleep was confirmed (backdated to onset start).
  final int sleepStartMs;

  /// Epoch milliseconds when wake was confirmed.
  /// Null means the session is still ongoing.
  final int? wakeTimeMs;

  /// Duration in whole minutes. Computed as (wakeTimeMs - sleepStartMs) / 60000.
  final int durationMinutes;

  /// Composite confidence score 0–100. Calculated by [SleepStateMachine].
  final int confidenceScore;

  /// True if this session was detected automatically by [SleepDetectionService].
  /// False if the user manually entered it via the log dialog.
  final bool isAutomatic;

  /// Tracking mode used for this automatic detection.
  final SleepTrackingMode trackingMode;

  /// When this record was first written to the database.
  final int createdAt;

  /// Reason why this session was closed.
  final ClosureReason closureReason;

  /// Optional: quality rating from manual entry (1–5 stars). Null for auto sessions.
  final int? manualQualityRating;

  /// Optional: factors noted by the user. Empty for auto sessions.
  final List<String> factors;

  /// Optional: user notes. Empty for auto sessions.
  final String notes;

  /// True if this session was recorded as a daytime nap.
  final bool isNap;

  /// Where this automatic session came from: `'phone_heuristic'` (this
  /// device's own on-sensor detection) or `'health_connect'` (synced from
  /// Health Connect — a wearable, Samsung Health, Pixel Bedtime tracking,
  /// etc). Meaningless for manual entries. Health Connect data is generally
  /// more accurate — it comes from purpose-built sleep tracking rather than
  /// phone-motion heuristics — so [SleepRepository] prefers it when both
  /// exist for the same night.
  final String source;

  const SleepSession({
    required this.id,
    required this.sleepStartMs,
    this.wakeTimeMs,
    required this.durationMinutes,
    required this.confidenceScore,
    required this.isAutomatic,
    this.trackingMode = SleepTrackingMode.hybrid,
    required this.createdAt,
    this.closureReason = ClosureReason.normalWake,
    this.isNap = false,
    this.manualQualityRating,
    this.factors = const [],
    this.notes = '',
    this.source = 'phone_heuristic',
  });

  static const String sourceHealthConnect = 'health_connect';
  static const String sourcePhoneHeuristic = 'phone_heuristic';

  bool get isFromHealthConnect => source == sourceHealthConnect;

  /// Qualitative detection confidence derived from [confidenceScore].
  DetectionConfidence get detectionConfidence =>
      DetectionConfidence.fromScore(confidenceScore);

  /// Duration as a formatted string, e.g. "7h 23m"
  String get durationLabel {
    final h = durationMinutes ~/ 60;
    final m = durationMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  /// Duration in fractional hours, used for chart display.
  double get durationHours => durationMinutes / 60.0;

  /// Whether this session is currently being recorded (no wake time yet).
  bool get isOngoing => wakeTimeMs == null;

  /// Source badge for UI display. Returns "💤 Nap", "🩺 Health Connect",
  /// "⭐ Auto (Hybrid)", "📱 Auto (Usage-Based)", or "✏️ Manual".
  String get sourceBadge {
    if (isNap) return '💤 Nap';
    if (!isAutomatic) return '✏️ Manual';
    if (isFromHealthConnect) return '🩺 Health Connect';
    return trackingMode.badgeLabel;
  }

  /// Formatted bedtime string e.g. "11:30 PM"
  String get bedtimeLabel {
    final dt = DateTime.fromMillisecondsSinceEpoch(sleepStartMs);
    final h = dt.hour;
    final m = dt.minute;
    final ampm = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $ampm';
  }

  /// Formatted wake time string e.g. "7:15 AM"
  String get wakeTimeLabel {
    if (wakeTimeMs == null) return 'Ongoing';
    final dt = DateTime.fromMillisecondsSinceEpoch(wakeTimeMs!);
    final h = dt.hour;
    final m = dt.minute;
    final ampm = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $ampm';
  }

  /// The single canonical date (YYYY-MM-DD) this session belongs to.
  ///
  /// For overnight sleep, this is the morning wake-up date (when the recovery applies).
  /// For naps or ongoing sessions, this is the start date.
  String get canonicalDateString {
    final dt = (wakeTimeMs != null && !isNap)
        ? DateTime.fromMillisecondsSinceEpoch(wakeTimeMs!)
        : DateTime.fromMillisecondsSinceEpoch(sleepStartMs);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// Checks whether this sleep session belongs to the given calendar [targetDate].
  bool matchesDate(DateTime targetDate) {
    final targetStr =
        '${targetDate.year}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}';
    return canonicalDateString == targetStr;
  }

  // ─── Factories ────────────────────────────────────────────────────────────

  /// Creates a SleepSession from a raw SQLite row in the `sleep_auto_sessions` table.
  factory SleepSession.fromAutoMap(Map<String, dynamic> map) {
    return SleepSession(
      id: map['id'] as String,
      sleepStartMs: map['sleepStartMs'] as int,
      wakeTimeMs: map['wakeTimeMs'] as int?,
      durationMinutes: map['durationMinutes'] as int? ?? 0,
      confidenceScore: map['confidenceScore'] as int? ?? 0,
      isAutomatic: true,
      trackingMode: SleepTrackingMode.fromString(map['trackingMode'] as String?),
      closureReason: ClosureReason.fromString(map['closureReason'] as String?),
      createdAt: map['createdAt'] as int? ?? 0,
      isNap: (map['isNap'] as int? ?? 0) == 1,
      factors: const [],
      notes: '',
      source: map['source'] as String? ?? sourcePhoneHeuristic,
    );
  }

  factory SleepSession.fromMap(Map<String, dynamic> map) =>
      SleepSession.fromAutoMap(map);

  /// Builds a session from a Health Connect `SLEEP_SESSION` record.
  /// [recordUuid] should be the Health Connect record's own stable UUID —
  /// used to derive a deterministic id so re-syncing the same period
  /// upserts the same row instead of creating duplicates.
  factory SleepSession.fromHealthConnect({
    required String recordUuid,
    required DateTime start,
    required DateTime end,
    required int createdAt,
  }) {
    final durationMinutes = (end.difference(start).inMinutes).clamp(0, 1440);
    return SleepSession(
      id: 'hc_$recordUuid',
      sleepStartMs: start.millisecondsSinceEpoch,
      wakeTimeMs: end.millisecondsSinceEpoch,
      durationMinutes: durationMinutes,
      // Health Connect data comes from purpose-built sleep tracking, not a
      // heuristic guess — treat it as maximally confident.
      confidenceScore: 95,
      isAutomatic: true,
      createdAt: createdAt,
      source: sourceHealthConnect,
    );
  }

  /// Bridges the existing [HealthSleepEntry] model (manual entry) into a
  /// unified [SleepSession] for display alongside auto-detected sessions.
  factory SleepSession.fromManualEntry({
    required String id,
    required String date, // YYYY-MM-DD
    required String bedtime, // HH:mm
    required String wakeTime, // HH:mm
    required double durationHours,
    required int qualityRating,
    required List<String> factors,
    required String notes,
    required int createdAt,
  }) {
    // Parse the base date (e.g. 2026-08-26).
    final parts = date.split('-').map(int.parse).toList();
    final wakeBaseDate = DateTime(parts[0], parts[1], parts[2]);

    // Parse HH:mm strings into minutes.
    int parseMins(String t) {
      final tp = t.split(':').map(int.parse).toList();
      return tp[0] * 60 + tp[1];
    }

    final bedMins = parseMins(bedtime);
    final wakeMins = parseMins(wakeTime);

    final wakeDt = wakeBaseDate.add(Duration(minutes: wakeMins));
    final sleepDt = wakeMins < bedMins
        ? wakeBaseDate.subtract(const Duration(days: 1)).add(Duration(minutes: bedMins))
        : wakeBaseDate.add(Duration(minutes: bedMins));

    return SleepSession(
      id: id,
      sleepStartMs: sleepDt.millisecondsSinceEpoch,
      wakeTimeMs: wakeDt.millisecondsSinceEpoch,
      durationMinutes: (durationHours * 60).round(),
      confidenceScore: 50,
      isAutomatic: false,
      trackingMode: SleepTrackingMode.hybrid,
      closureReason: ClosureReason.normalWake,
      createdAt: createdAt,
      manualQualityRating: qualityRating,
      factors: factors,
      notes: notes,
    );
  }

  // ─── Serialization (auto sessions only) ──────────────────────────────────

  Map<String, dynamic> toAutoMap() {
    return {
      'id': id,
      'sleepStartMs': sleepStartMs,
      'wakeTimeMs': wakeTimeMs,
      'durationMinutes': durationMinutes,
      'confidenceScore': confidenceScore,
      'trackingMode': trackingMode.name,
      'closureReason': closureReason.name,
      'createdAt': createdAt,
      'isNap': isNap ? 1 : 0,
      'source': source,
    };
  }

  /// Returns a copy with the wake time and closure reason filled in, used when a session ends.
  SleepSession copyWithWake({
    required int wakeTimeMs,
    ClosureReason? reason,
  }) {
    final durMins = ((wakeTimeMs - sleepStartMs) / 60000).round().clamp(0, 1440);
    return SleepSession(
      id: id,
      sleepStartMs: sleepStartMs,
      wakeTimeMs: wakeTimeMs,
      durationMinutes: durMins,
      confidenceScore: confidenceScore,
      isAutomatic: isAutomatic,
      trackingMode: trackingMode,
      closureReason: reason ?? closureReason,
      createdAt: createdAt,
      isNap: isNap,
      manualQualityRating: manualQualityRating,
      factors: factors,
      notes: notes,
      source: source,
    );
  }
}
