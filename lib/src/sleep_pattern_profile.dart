/// Sleep Pattern Profile
///
/// Learns the user's personal sleep timing from historical sessions and
/// exposes a circadian-adaptive weight used by [SleepStateMachine] to
/// amplify or dampen detection sensitivity based on when the user
/// typically sleeps.
///
/// Architecture:
///   [SleepPatternLearner.buildProfile]  — computes a new profile from sessions.
///   [SleepPatternLearner.circadianWeight] — Gaussian weight centred on typical bedtime.
///   [SleepPatternLearner.save / load]  — SharedPreferences JSON persistence.
///
/// Minimum sessions for a confident profile: 3 (usable), 7 (good), 14+ (excellent).
/// Below 3 sessions the profile returns a flat weight of 1.0 everywhere.
///
/// ⚠️ NOT clinical. Heuristic wellness estimate only.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'sleep_session.dart';

// ─── Model ───────────────────────────────────────────────────────────────────

/// Learned sleep-timing profile derived from completed sessions.
class SleepPatternProfile {
  /// Typical bedtime in minutes since midnight (circular mean).
  /// e.g. 11:18 PM = 1398 min.
  final double typicalBedtimeMins;

  /// Typical wake time in minutes since midnight (circular mean).
  final double typicalWakeMins;

  /// Standard deviation of bedtime across sessions (minutes).
  /// Smaller = more consistent schedule.
  final double bedtimeVarianceMins;

  /// Average sleep duration across sessions (minutes).
  final int avgSleepDurationMins;

  /// Number of sessions used to build this profile.
  final int sessionCount;

  /// Confidence level 0.0–1.0 based on session count.
  double get confidence {
    if (sessionCount < 3) return 0.0;
    if (sessionCount >= 14) return 1.0;
    return (sessionCount - 3) / 11.0;
  }

  /// Whether the profile has enough data to be useful.
  bool get isUsable => sessionCount >= 3;

  const SleepPatternProfile({
    required this.typicalBedtimeMins,
    required this.typicalWakeMins,
    required this.bedtimeVarianceMins,
    required this.avgSleepDurationMins,
    required this.sessionCount,
  });

  // ── Formatting ────────────────────────────────────────────────────────────

  /// Formats minutes-since-midnight to "h:mm AM/PM".
  static String _fmtMins(double totalMins) {
    final m = totalMins.round() % 1440;
    final h = m ~/ 60;
    final min = m % 60;
    final period = h < 12 ? 'AM' : 'PM';
    final displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$displayH:${min.toString().padLeft(2, '0')} $period';
  }

  String get bedtimeLabel => _fmtMins(typicalBedtimeMins);
  String get wakeLabel => _fmtMins(typicalWakeMins);

  String get avgDurationLabel {
    final h = avgSleepDurationMins ~/ 60;
    final m = avgSleepDurationMins % 60;
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

  String get consistencyLabel {
    if (bedtimeVarianceMins <= 15) return 'Very consistent';
    if (bedtimeVarianceMins <= 30) return 'Consistent';
    if (bedtimeVarianceMins <= 60) return 'Variable';
    return 'Irregular';
  }

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'typicalBedtimeMins': typicalBedtimeMins,
        'typicalWakeMins': typicalWakeMins,
        'bedtimeVarianceMins': bedtimeVarianceMins,
        'avgSleepDurationMins': avgSleepDurationMins,
        'sessionCount': sessionCount,
      };

  factory SleepPatternProfile.fromJson(Map<String, dynamic> j) =>
      SleepPatternProfile(
        typicalBedtimeMins: (j['typicalBedtimeMins'] as num).toDouble(),
        typicalWakeMins: (j['typicalWakeMins'] as num).toDouble(),
        bedtimeVarianceMins: (j['bedtimeVarianceMins'] as num).toDouble(),
        avgSleepDurationMins: j['avgSleepDurationMins'] as int,
        sessionCount: j['sessionCount'] as int,
      );
}

// ─── Learner ─────────────────────────────────────────────────────────────────

class SleepPatternLearner {
  SleepPatternLearner._();

  static const String _prefKey = 'sleep_pattern_profile_v1';

  // ── Profile building ──────────────────────────────────────────────────────

  /// Builds a [SleepPatternProfile] from a list of completed [SleepSession]s.
  /// Requires at least 3 sessions; returns null if fewer sessions are available.
  static SleepPatternProfile? buildProfile(List<SleepSession> sessions) {
    final completed = sessions.where((s) => !s.isOngoing).toList();
    if (completed.isEmpty) return null;

    // ── Circular mean for bedtime (handles midnight wrap correctly) ─────────
    final bedtimeMins = completed.map((s) {
      final dt = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
      int m = dt.hour * 60 + dt.minute;
      // Normalise: times before 6 AM are treated as "next day" (add 1440).
      if (m < 360) m += 1440;
      return m.toDouble();
    }).toList();

    final wakeMins = completed.map((s) {
      if (s.wakeTimeMs == null) return null;
      final dt = DateTime.fromMillisecondsSinceEpoch(s.wakeTimeMs!);
      int m = dt.hour * 60 + dt.minute;
      if (m < 360) m += 1440;
      return m.toDouble();
    }).whereType<double>().toList();

    final typicalBedtime = _circularMean(bedtimeMins) % 1440;
    final typicalWake = wakeMins.isNotEmpty ? _circularMean(wakeMins) % 1440 : (typicalBedtime + 480) % 1440;

    // Standard deviation of bedtime (variance in minutes)
    final bedtimeMean = bedtimeMins.reduce((a, b) => a + b) / bedtimeMins.length;
    final variance = bedtimeMins.map((m) => math.pow(m - bedtimeMean, 2)).reduce((a, b) => a + b) / bedtimeMins.length;
    final stdDev = math.sqrt(variance);

    // Average sleep duration
    final durations = completed.where((s) => s.durationMinutes > 0).toList();
    final avgDuration = durations.isEmpty
        ? 480
        : (durations.map((s) => s.durationMinutes).reduce((a, b) => a + b) / durations.length).round();

    return SleepPatternProfile(
      typicalBedtimeMins: typicalBedtime,
      typicalWakeMins: typicalWake,
      bedtimeVarianceMins: stdDev,
      avgSleepDurationMins: avgDuration,
      sessionCount: completed.length,
    );
  }

  // ── Circadian adaptive weight ──────────────────────────────────────────────

  /// Returns a circadian weight multiplier (0.5–1.5) for the given [now] time,
  /// based on the user's [profile].
  ///
  /// The weight is a Gaussian centred on [profile.typicalBedtimeMins] with
  /// sigma = max(20, profile.bedtimeVarianceMins).
  ///
  /// Returns 1.0 (neutral) if the profile is not usable.
  static double circadianWeight(DateTime now, SleepPatternProfile? profile) {
    if (profile == null || !profile.isUsable) return 1.0;

    // Current time in minutes since midnight, normalised to 0–1440 with same
    // midnight-wrap logic as buildProfile.
    int nowMins = now.hour * 60 + now.minute;
    if (nowMins < 360) nowMins += 1440;

    final centre = profile.typicalBedtimeMins;
    final sigma = math.max(20.0, profile.bedtimeVarianceMins);

    // Circular distance (minutes) between now and typical bedtime.
    double diff = (nowMins - centre).abs().toDouble();
    if (diff > 720) diff = 1440 - diff; // wrap around midnight

    // Gaussian: peaks at 1.40 at exact bedtime, falls to ~0.70 at 2σ away.
    final gaussian = math.exp(-0.5 * math.pow(diff / sigma, 2));
    // Map gaussian (0–1) to weight (0.60–1.40).
    return 0.60 + gaussian * 0.80;
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Saves the profile to SharedPreferences.
  static Future<void> save(SleepPatternProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(profile.toJson()));
  }

  /// Loads the profile from SharedPreferences. Returns null if none saved.
  static Future<SleepPatternProfile?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null) return null;
      return SleepPatternProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Builds and saves an updated profile from the given sessions.
  /// No-op if fewer than 1 session exists.
  static Future<SleepPatternProfile?> updateAndSave(List<SleepSession> sessions) async {
    final profile = buildProfile(sessions);
    if (profile != null) await save(profile);
    return profile;
  }

  // ── Internal: circular mean ───────────────────────────────────────────────

  /// Computes the circular (von Mises) mean of a list of minute values
  /// on a 1440-minute circle.
  static double _circularMean(List<double> minuteValues) {
    if (minuteValues.isEmpty) return 0;
    if (minuteValues.length == 1) return minuteValues.first;

    double sinSum = 0, cosSum = 0;
    for (final m in minuteValues) {
      final angle = 2 * math.pi * m / 1440.0;
      sinSum += math.sin(angle);
      cosSum += math.cos(angle);
    }
    final meanAngle = math.atan2(sinSum / minuteValues.length, cosSum / minuteValues.length);
    final normalised = meanAngle >= 0 ? meanAngle : meanAngle + 2 * math.pi;
    return normalised / (2 * math.pi) * 1440;
  }
}
