/// Sleep Analysis Engine
///
/// Computes session-level sleep quality metrics from a completed [SleepSession]
/// and its associated per-minute [SleepEpoch] records.
///
/// Focuses on objective, measurable session characteristics:
///   - Estimated sleep duration vs time in bed
///   - Detected awakening count (sustained ≥5 min activity) vs brief interruptions
///   - Longest continuous sleep period
///   - Sleep efficiency percentage
///   - Data coverage & tracking reliability
///   - Sleep quality score (composite 0–100)
///
/// ⚠️ NOT clinical-grade. Heuristic wellness estimates only.
library;

import 'dart:math' as math;
import 'sleep_epoch.dart';
import 'sleep_session.dart';

// ─── Result Model ─────────────────────────────────────────────────────────────

/// Full analysis result for a single sleep session.
class SleepAnalysisResult {
  /// Total time from sleep start to final wake (minutes).
  final int timeInBedMins;

  /// Estimated minutes of actual sleep (time in bed minus awake/interruption duration).
  final int totalSleepMins;

  /// Total detected awake/interruption duration in minutes.
  final int awakeningDurationMins;

  /// Number of distinct sustained awakening events (≥5 min).
  final int awakeningCount;

  /// Number of brief interruptions (<5 min).
  final int briefInterruptionCount;

  /// Longest continuous sleep period without awakening (minutes).
  final int longestContinuousSleepMins;

  /// Sleep efficiency: (totalSleepMins / timeInBedMins) × 100, clamped 0–100.
  final double sleepEfficiency;

  /// Percentage of expected epochs successfully collected during the session.
  final double dataCoveragePercent;

  /// Composite sleep quality score 0–100.
  final int sleepScore;

  const SleepAnalysisResult({
    required this.timeInBedMins,
    required this.totalSleepMins,
    required this.awakeningDurationMins,
    required this.awakeningCount,
    this.briefInterruptionCount = 0,
    required this.longestContinuousSleepMins,
    required this.sleepEfficiency,
    this.dataCoveragePercent = 100.0,
    required this.sleepScore,
  });

  // ── Convenience labels ──────────────────────────────────────────────────────

  String get sleepScoreLabel {
    if (sleepScore >= 85) return 'Excellent';
    if (sleepScore >= 70) return 'Good';
    if (sleepScore >= 55) return 'Fair';
    return 'Poor';
  }

  String get efficiencyLabel => '${sleepEfficiency.toStringAsFixed(0)}%';
  String get dataCoverageLabel => '${dataCoveragePercent.toStringAsFixed(0)}%';

  String get totalSleepLabel => _fmtMins(totalSleepMins);
  String get sessionDurationLabel => _fmtMins(timeInBedMins);
  String get timeInBedLabel => _fmtMins(timeInBedMins);
  String get longestStretchLabel => _fmtMins(longestContinuousSleepMins);
  String get awakeningDurationLabel => _fmtMins(awakeningDurationMins);

  static String _fmtMins(int mins) {
    if (mins <= 0) return '—';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

// ─── Engine ──────────────────────────────────────────────────────────────────

class SleepAnalysisEngine {
  SleepAnalysisEngine._();

  // ── Configurable thresholds ────────────────────────────────────────────────

  /// Minimum consecutive awakening epochs to count as a distinct sustained awakening event.
  /// Matches the state machine's wake confirmation period (5 minutes).
  static const int _minAwakeningEpochs = 5;

  // ── Primary entry point ────────────────────────────────────────────────────

  /// Analyzes a completed [session] using its per-minute [epochs].
  static SleepAnalysisResult analyze({
    required SleepSession session,
    required List<SleepEpoch> epochs,
    required double targetHours,
    int consistencyScore = 50,
  }) {
    if (epochs.isEmpty) {
      return _analyzeWithoutEpochs(
        session: session,
        targetHours: targetHours,
        consistencyScore: consistencyScore,
      );
    }

    final timeInBed = math.max(1, session.durationMinutes);
    final awakeEpochs = epochs.where((e) => e.isAwakening).toList();

    // Data coverage calculation: captured epochs vs expected session duration
    final double coverage = (epochs.length / timeInBed * 100.0).clamp(0.0, 100.0);

    // Count sustained awakenings (≥5 min) and brief interruptions (<5 min)
    final counts = _categorizeAwakenings(epochs);
    final int sustainedAwakenings = counts['sustained'] ?? 0;
    final int briefInterruptions = counts['brief'] ?? 0;

    final int awakeDurationMins = awakeEpochs.length;
    final int totalSleepMins = math.max(0, timeInBed - awakeDurationMins);
    final int longestStretch = _longestContinuousSleepMins(epochs);

    final double efficiency = timeInBed > 0
        ? ((totalSleepMins / timeInBed) * 100).clamp(0.0, 100.0)
        : 0.0;

    final int score = _computeScore(
      totalSleepMins: totalSleepMins,
      targetHours: targetHours,
      efficiency: efficiency,
      awakeningCount: sustainedAwakenings,
      consistencyScore: consistencyScore,
    );

    return SleepAnalysisResult(
      timeInBedMins: timeInBed,
      totalSleepMins: totalSleepMins,
      awakeningDurationMins: awakeDurationMins,
      awakeningCount: sustainedAwakenings,
      briefInterruptionCount: briefInterruptions,
      longestContinuousSleepMins: longestStretch,
      sleepEfficiency: efficiency,
      dataCoveragePercent: coverage,
      sleepScore: score,
    );
  }

  // ── Fallback: no epoch data ─────────────────────────────────────────────────

  static SleepAnalysisResult _analyzeWithoutEpochs({
    required SleepSession session,
    required double targetHours,
    int consistencyScore = 50,
  }) {
    final timeInBed = math.max(1, session.durationMinutes);
    const double assumedEfficiency = 90.0;
    final int totalSleepMins = ((timeInBed * assumedEfficiency) / 100).round();

    final int score = _computeScore(
      totalSleepMins: totalSleepMins,
      targetHours: targetHours,
      efficiency: assumedEfficiency,
      awakeningCount: 0,
      consistencyScore: consistencyScore,
      noEpochPenalty: 15,
    );

    return SleepAnalysisResult(
      timeInBedMins: timeInBed,
      totalSleepMins: totalSleepMins,
      awakeningDurationMins: 0,
      awakeningCount: -1,
      briefInterruptionCount: 0,
      longestContinuousSleepMins: totalSleepMins,
      sleepEfficiency: assumedEfficiency,
      dataCoveragePercent: 0.0,
      sleepScore: score,
    );
  }

  // ── Score formula ──────────────────────────────────────────────────────────

  /// Composite sleep quality score 0–100:
  ///   1. Duration    (0–40 pts): actual sleep vs target hours
  ///   2. Efficiency  (0–30 pts): sleep / time-in-bed ratio
  ///   3. Continuity  (0–20 pts): penalises sustained awakenings
  ///   4. Consistency (0–10 pts): bedtime regularity
  static int _computeScore({
    required int totalSleepMins,
    required double targetHours,
    required double efficiency,
    required int awakeningCount,
    required int consistencyScore,
    int noEpochPenalty = 0,
  }) {
    final targetMins = (targetHours * 60).round();

    // Duration component (0–40)
    final durationRatio = targetMins > 0
        ? (totalSleepMins / targetMins).clamp(0.0, 1.0)
        : 0.0;
    final overagePenalty = totalSleepMins > 600
        ? ((totalSleepMins - 600) / 60.0 * 4).round().clamp(0, 10)
        : 0;
    final durationPts =
        ((durationRatio * 40).round() - overagePenalty).clamp(0, 40);

    // Efficiency component (0–30)
    final efficiencyPts = ((efficiency / 100.0) * 30).round().clamp(0, 30);

    // Continuity component (0–20)
    final int continuityPts;
    if (awakeningCount < 0) {
      continuityPts = 10;
    } else {
      continuityPts = math.max(0, 20 - awakeningCount * 6);
    }

    // Consistency component (0–10)
    final consistencyPts =
        ((consistencyScore / 100.0) * 10).round().clamp(0, 10);

    final raw = durationPts +
        efficiencyPts +
        continuityPts +
        consistencyPts -
        noEpochPenalty;
    return raw.clamp(0, 100);
  }

  // ── Epoch helpers ──────────────────────────────────────────────────────────

  /// Categorizes awakenings into sustained (≥5 min) and brief (<5 min).
  static Map<String, int> _categorizeAwakenings(List<SleepEpoch> epochs) {
    int sustained = 0;
    int brief = 0;
    int currentRun = 0;

    for (final e in epochs) {
      if (e.isAwakening) {
        currentRun++;
      } else {
        if (currentRun >= _minAwakeningEpochs) {
          sustained++;
        } else if (currentRun > 0) {
          brief++;
        }
        currentRun = 0;
      }
    }
    if (currentRun >= _minAwakeningEpochs) {
      sustained++;
    } else if (currentRun > 0) {
      brief++;
    }

    return {'sustained': sustained, 'brief': brief};
  }

  /// Returns the length of the longest uninterrupted sleep stretch (minutes).
  static int _longestContinuousSleepMins(List<SleepEpoch> epochs) {
    int longest = 0;
    int current = 0;
    for (final e in epochs) {
      if (!e.isAwakening) {
        current++;
        if (current > longest) longest = current;
      } else {
        current = 0;
      }
    }
    return longest;
  }

  // ── Objective Insights ────────────────────────────────────────────────────

  /// Generates objective personalized insights from the analysis result.
  static List<String> getTips({
    required SleepAnalysisResult result,
    required double targetHours,
    int recentNapCount = 0,
    int? medianBedtimeVarianceMins,
  }) {
    final tips = <String>[];
    final targetMins = (targetHours * 60).round();
    final diffMins = targetMins - result.totalSleepMins;

    if (diffMins > 15) {
      final h = diffMins ~/ 60;
      final m = diffMins % 60;
      final diffLabel = h > 0 ? '${h}h ${m}m' : '${m}m';
      tips.add('Sleep duration was $diffLabel below your ${targetHours.toStringAsFixed(0)}h target.');
    } else if (result.totalSleepMins >= targetMins) {
      tips.add('Met your ${targetHours.toStringAsFixed(0)}h sleep target for this session.');
    }

    if (medianBedtimeVarianceMins != null && medianBedtimeVarianceMins > 0) {
      tips.add('Bedtime was within ${medianBedtimeVarianceMins}m of your 7-day median.');
    }

    if (result.awakeningCount > 0) {
      tips.add('Detected ${result.awakeningCount} sustained awakening(s) during the session.');
    } else if (result.briefInterruptionCount > 0) {
      tips.add('Recorded ${result.briefInterruptionCount} brief interruption(s) without full wake.');
    }

    if (recentNapCount >= 3) {
      tips.add('Logged $recentNapCount naps recently.');
    }

    return tips.take(4).toList();
  }
}
