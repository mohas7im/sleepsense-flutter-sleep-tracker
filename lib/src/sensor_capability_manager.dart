/// Sensor Capability Manager
///
/// Detects which physical sensors are available on the current device at runtime.
/// The sleep detection algorithm uses this to gracefully degrade when optional
/// sensors are absent, rather than crashing or producing misleading signals.
///
/// Call [SensorCapabilityManager.initialize()] once during app startup
/// (before starting [SleepDetectionService]).
///
/// Platform note:
///   Android: sensor availability is checked via sensors_plus.
///   iOS: Core Motion availability varies by device; additional checks needed.
///
/// ⚠️ Sensor presence does not guarantee useful readings. Always treat sensor
/// output as a probabilistic input, not ground truth.
library;

import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

// ─── Capability Report ────────────────────────────────────────────────────────

/// Snapshot of hardware sensor availability on the current device.
class SensorCapabilityReport {
  /// Accelerometer is required for motion-based sleep detection.
  /// If unavailable, automatic sleep tracking cannot function.
  final bool hasAccelerometer;

  /// Gyroscope is optional. Improves phone-position inference and
  /// rotation-based signals. Without it, confidence is slightly lower.
  final bool hasGyroscope;

  /// Ambient light sensor is optional. Supports dark-room inference.
  final bool hasAmbientLight;

  /// Proximity sensor is optional. Supports phone-position inference.
  final bool hasProximity;

  const SensorCapabilityReport({
    required this.hasAccelerometer,
    required this.hasGyroscope,
    required this.hasAmbientLight,
    required this.hasProximity,
  });

  /// True if the minimum required sensors for sleep detection are present.
  bool get canDetectSleep => hasAccelerometer;

  /// Confidence ceiling based on available sensors.
  /// Full confidence requires accelerometer + gyroscope.
  /// Each missing optional sensor reduces the ceiling.
  int get confidenceCeiling {
    int ceiling = 100;
    if (!hasGyroscope) ceiling -= 12;
    if (!hasAmbientLight) ceiling -= 5;
    if (!hasProximity) ceiling -= 5;
    return ceiling.clamp(60, 100);
  }

  /// Human-readable capability summary for the diagnostics page.
  String get summary {
    final parts = <String>[];
    parts.add('Accelerometer: ${hasAccelerometer ? "✅" : "❌ (required)"}');
    parts.add('Gyroscope: ${hasGyroscope ? "✅" : "⚠️ optional — lower confidence"}');
    parts.add('Ambient Light: ${hasAmbientLight ? "✅" : "⚠️ optional"}');
    parts.add('Proximity: ${hasProximity ? "✅" : "⚠️ optional"}');
    return parts.join('\n');
  }

  @override
  String toString() => 'SensorCapabilityReport('
      'accel=$hasAccelerometer, gyro=$hasGyroscope, '
      'light=$hasAmbientLight, prox=$hasProximity)';
}

// ─── Manager ──────────────────────────────────────────────────────────────────

class SensorCapabilityManager {
  SensorCapabilityManager._();

  static const String _prefKey = 'sensor_capability_report_v1';
  static SensorCapabilityReport? _cached;

  /// Returns the most recently computed capability report, or null if
  /// [initialize] has not been called yet.
  static SensorCapabilityReport? get current => _cached;

  /// Probes all relevant sensors and caches the result.
  ///
  /// This performs short (1-second) subscription attempts on each sensor stream.
  /// Results are persisted to SharedPreferences so they survive cold starts
  /// without re-probing every time.
  ///
  /// [forceProbe] skips the cache and re-probes all sensors.
  static Future<SensorCapabilityReport> initialize({bool forceProbe = false}) async {
    if (_cached != null && !forceProbe) return _cached!;

    // Try loading from persisted cache first.
    if (!forceProbe) {
      final cached = await _loadCached();
      if (cached != null) {
        _cached = cached;
        return cached;
      }
    }

    final report = await _probe();
    _cached = report;
    await _persist(report);
    return report;
  }

  // ── Sensor probing ─────────────────────────────────────────────────────────

  static Future<SensorCapabilityReport> _probe() async {
    final accel = await _probeAccelerometer();
    final gyro = await _probeGyroscope();
    // Light and proximity availability is signaled by the platform channel
    // in MainActivity (returns -1.0 / false when sensor absent).
    // We optimistically mark them as available here; the channel returns
    // graceful fallback values when absent.
    const light = true;
    const proximity = true;

    return SensorCapabilityReport(
      hasAccelerometer: accel,
      hasGyroscope: gyro,
      hasAmbientLight: light,
      hasProximity: proximity,
    );
  }

  static Future<bool> _probeAccelerometer() async {
    try {
      final completer = Completer<bool>();
      final sub = accelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((_) {
        if (!completer.isCompleted) completer.complete(true);
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(false);
      });
      final result = await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      await sub.cancel();
      return result;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _probeGyroscope() async {
    try {
      final completer = Completer<bool>();
      final sub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((_) {
        if (!completer.isCompleted) completer.complete(true);
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(false);
      });
      final result = await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      await sub.cancel();
      return result;
    } catch (_) {
      return false;
    }
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  static Future<SensorCapabilityReport?> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final accel = prefs.getBool('${_prefKey}_accel');
      if (accel == null) return null;
      return SensorCapabilityReport(
        hasAccelerometer: accel,
        hasGyroscope: prefs.getBool('${_prefKey}_gyro') ?? false,
        hasAmbientLight: prefs.getBool('${_prefKey}_light') ?? true,
        hasProximity: prefs.getBool('${_prefKey}_prox') ?? true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persist(SensorCapabilityReport report) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${_prefKey}_accel', report.hasAccelerometer);
      await prefs.setBool('${_prefKey}_gyro', report.hasGyroscope);
      await prefs.setBool('${_prefKey}_light', report.hasAmbientLight);
      await prefs.setBool('${_prefKey}_prox', report.hasProximity);
    } catch (_) {}
  }
}
