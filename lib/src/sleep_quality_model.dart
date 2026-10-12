/// Sleep Quality Model
///
/// Computes a multi-dimensional quality score (0–100) for a sleep session.
///
/// Components:
///   1. Duration score   (0–40): actual sleep vs. target hours ratio.
///   2. Efficiency score (0–30): sleep / time-in-bed ratio from [SleepAnalysisEngine].
///   3. Continuity score (0–20): penalises awakening events.
///   4. Consistency score(0–10): bedtime regularity (passed in from repository).
///
/// Note: Previous versions included a "stage distribution score" based on
/// estimated REM/Deep proportions. This has been removed — consumer-phone
/// actigraphy cannot reliably distinguish sleep stages.
///
/// NOT clinical-grade. These are heuristic wellness estimates only.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'sleep_analysis_engine.dart';
import 'sleep_session.dart';

// ─── Data Classes ─────────────────────────────────────────────────────────────

/// Detailed breakdown of a session quality estimate.
class SleepQualityScore {
  final int overall;
  final int durationScore;
  final int consistencyScore;
  final int timingScore;
  final int efficiencyScore;

  /// Number of awakenings detected in epoch data. -1 if no epoch data.
  final int awakeningCount;

  String get label {
    if (overall >= 85) return 'Excellent';
    if (overall >= 70) return 'Good';
    if (overall >= 55) return 'Fair';
    return 'Poor';
  }

  String get emoji {
    if (overall >= 85) return 'star';
    if (overall >= 70) return 'sleep';
    if (overall >= 55) return 'neutral';
    return 'sad';
  }

  Color get color {
    if (overall >= 85) return const Color(0xFF10B981);
    if (overall >= 70) return const Color(0xFF6366F1);
    if (overall >= 55) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  const SleepQualityScore({
    required this.overall,
    required this.durationScore,
    required this.consistencyScore,
    required this.timingScore,
    required this.efficiencyScore,
    this.awakeningCount = -1,
  });
}

// ─── Model ────────────────────────────────────────────────────────────────────

class SleepQualityModel {
  SleepQualityModel._();

  /// Compute a [SleepQualityScore] for a session.
  ///
  /// [analysisResult] is optional — if null (manual entry with no epoch data),
  /// efficiency and continuity are estimated conservatively.
  static SleepQualityScore compute({
    required SleepSession session,
    required double targetHours,
    required int consistencyScore,
    List<SleepSession> recentSessions = const [],
    SleepAnalysisResult? analysisResult,
  }) {
    final actualHours = session.durationHours;
    final durationRatio = (actualHours / targetHours).clamp(0.0, 1.0);
    final excessPenalty = actualHours > 10.0
        ? ((actualHours - 10.0) * 5).round().clamp(0, 15)
        : 0;
    final durationScore =
        ((durationRatio * 40).round() - excessPenalty).clamp(0, 40);

    final consistencyPts = (consistencyScore * 0.10).round().clamp(0, 10);

    int timingPts = 10;
    if (recentSessions.isNotEmpty) {
      final avgBedtimeMins = _circularAvgBedtimeMins(recentSessions);
      final thisBedtimeMins = _bedtimeMins(session);
      final diffMins = (thisBedtimeMins - avgBedtimeMins).abs();
      timingPts = (20 - (diffMins / 90.0 * 20)).round().clamp(0, 20);
    }

    // Efficiency + continuity from analysis engine.
    int efficiencyPts = 15; // default mid when no epoch data
    int awakeningCount = -1;
    if (analysisResult != null) {
      efficiencyPts =
          ((analysisResult.sleepEfficiency / 100.0) * 30).round().clamp(0, 30);
      awakeningCount = analysisResult.awakeningCount;
    }

    final rawTotal = durationScore + consistencyPts + timingPts + efficiencyPts;
    final overall = rawTotal.clamp(0, 100);

    return SleepQualityScore(
      overall: overall,
      durationScore: durationScore.clamp(0, 100),
      consistencyScore: consistencyPts,
      timingScore: timingPts,
      efficiencyScore: efficiencyPts,
      awakeningCount: awakeningCount,
    );
  }

  static TimeOfDay? getOptimalBedtime(List<SleepSession> sessions) {
    if (sessions.isEmpty) return null;
    double sinSum = 0.0;
    double cosSum = 0.0;
    for (final s in sessions) {
      final mins = _bedtimeMins(s);
      final angle = 2 * math.pi * mins / 1440.0;
      sinSum += math.sin(angle);
      cosSum += math.cos(angle);
    }
    final avgAngle = math.atan2(sinSum, cosSum);
    final normalised =
        avgAngle >= 0 ? avgAngle : avgAngle + 2 * math.pi;
    final avgMins = (normalised / (2 * math.pi) * 1440).round() % 1440;
    return TimeOfDay(hour: avgMins ~/ 60, minute: avgMins % 60);
  }

  static List<String> getPersonalizedTips(
    SleepQualityScore score,
    List<SleepSession> sessions,
    double targetHours, {
    SleepAnalysisResult? analysisResult,
  }) {
    final tips = <String>[];

    if (score.durationScore < 20) {
      tips.add(
        'You are significantly under your ${targetHours.toStringAsFixed(1)}h goal. '
        'Try moving bedtime 30 minutes earlier tonight.',
      );
    } else if (score.durationScore >= 38) {
      tips.add(
          'Great job hitting your sleep duration goal! Keep the same bedtime tomorrow.');
    }

    if (score.consistencyScore < 5) {
      tips.add(
        'Your bedtime varies a lot. A consistent schedule — even on weekends — '
        'improves overall sleep quality.',
      );
    }

    if (score.timingScore < 8) {
      tips.add(
        'Your bedtime tonight was noticeably different from your usual pattern. '
        'Try to stay within 30 minutes of your average.',
      );
    }

    if (analysisResult != null) {
      if (analysisResult.sleepEfficiency < 80 &&
          analysisResult.awakeningCount > 0) {
        tips.add(
          'Your sleep was interrupted ${analysisResult.awakeningCount} time(s). '
          'Reducing screen light after 9 PM can improve sleep continuity.',
        );
      }
      if (analysisResult.longestContinuousSleepMins < 90) {
        tips.add(
          'Your longest uninterrupted sleep stretch was only '
          '${analysisResult.longestStretchLabel}. '
          'A consistent pre-sleep routine can extend this.',
        );
      }
    }

    final napCount = sessions.where((s) => s.isNap).length;
    if (napCount >= 3) {
      tips.add(
        'You have had $napCount naps recently. '
        'Keep naps under 20 minutes before 3 PM.',
      );
    }

    if (sessions.isNotEmpty) {
      final totalHours = sessions.fold(0.0, (s, e) => s + e.durationHours);
      final debt = (targetHours * sessions.length) - totalHours;
      if (debt > 3) {
        tips.add(
          'You have about ${debt.toStringAsFixed(1)}h of accumulated sleep debt. '
          'Recover with an extra 30–45 minutes per night over a week.',
        );
      }
    }

    tips.add('Staying well-hydrated during the day supports deeper, more restful sleep.');

    return tips.take(5).toList();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  static int _bedtimeMins(SleepSession s) {
    final dt = DateTime.fromMillisecondsSinceEpoch(s.sleepStartMs);
    int m = dt.hour * 60 + dt.minute;
    // Normalise midnight-crossing: times before 6 AM are treated as late night.
    if (m < 360) m += 1440;
    return m;
  }

  static double _circularAvgBedtimeMins(List<SleepSession> sessions) {
    double sinSum = 0.0;
    double cosSum = 0.0;
    for (final s in sessions) {
      final mins = _bedtimeMins(s);
      final angle = 2 * math.pi * mins / 1440.0;
      sinSum += math.sin(angle);
      cosSum += math.cos(angle);
    }
    final avgAngle = math.atan2(sinSum, cosSum);
    final normalised = avgAngle >= 0 ? avgAngle : avgAngle + 2 * math.pi;
    return (normalised / (2 * math.pi) * 1440) % 1440;
  }
}
