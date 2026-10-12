/// Sensor orchestration service for automatic sleep detection.
///
/// Responsibilities:
///   1. Collect accelerometer samples for 12 seconds per minute
///      (battery-efficient burst sampling, never continuous).
///   2. Read battery/charging state via battery_plus.
///   3. Read Activity Recognition status on demand.
///   4. Feed the assembled [SensorSnapshot] into [SleepStateMachine] once/minute.
///   5. Persist session boundaries via [SleepRepository].
///
/// ⚠️ Isolate lifetime: This service's `Timer.periodic` and sensor streams
/// only run for as long as the Dart isolate hosting them is alive. A plain
/// `FlutterActivity` engine (the one behind the app's UI) is destroyed by
/// Android whenever its task is removed (e.g. the user swipes the app out
/// of Recent Apps — the single most common thing people do right before
/// sleep) or the OS reclaims it under memory pressure. For real overnight
/// tracking this service MUST be started from the headless isolate managed
/// by `flutter_background_service` (see `sleep_background_service.dart`),
/// not from the main UI isolate — otherwise "tracking" silently stops the
/// moment the Activity dies, even though a foreground notification may
/// still claim it's active. Use an in-process instance only for on-demand
/// diagnostic bursts, never for the real overnight loop.
///
/// Screen on/off and unlock events come from this package's native plugin
/// ([SleepSignals]), which is registered in every engine — including the
/// headless background isolate used overnight — so waking up is seen even
/// with the app closed.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:pedometer/pedometer.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sleep_epoch.dart';
import 'sleep_pattern_profile.dart';
import 'sleep_repository.dart';
import 'sleep_session.dart';
import 'sleep_signals.dart';
import 'sleep_state_machine.dart';
import 'sensor_capability_manager.dart';
import 'sleep_detection_logger.dart';

/// A night's sleep that just ended — the user woke up and the session was
/// saved. Delivered through [SleepDetectionService.onSleepFinished].
class SleepFinishedEvent {
  final String sessionId;
  final DateTime sleepStart;
  final DateTime wakeTime;
  final int durationMinutes;

  /// Rough 30–100 score from duration alone; the full analysis is available
  /// from [SleepRepository.getSessionById].
  final int sleepScore;

  const SleepFinishedEvent({
    required this.sessionId,
    required this.sleepStart,
    required this.wakeTime,
    required this.durationMinutes,
    required this.sleepScore,
  });

  Map<String, dynamic> toMap() => {
        'sessionId': sessionId,
        'sleepStartMs': sleepStart.millisecondsSinceEpoch,
        'wakeTimeMs': wakeTime.millisecondsSinceEpoch,
        'durationMinutes': durationMinutes,
        'sleepScore': sleepScore,
      };

  factory SleepFinishedEvent.fromMap(Map<String, dynamic> map) => SleepFinishedEvent(
        sessionId: map['sessionId'] as String,
        sleepStart: DateTime.fromMillisecondsSinceEpoch(map['sleepStartMs'] as int),
        wakeTime: DateTime.fromMillisecondsSinceEpoch(map['wakeTimeMs'] as int),
        durationMinutes: map['durationMinutes'] as int,
        sleepScore: map['sleepScore'] as int,
      );
}

/// Keys used in SharedPreferences to persist service state across restarts.
class _PrefKeys {
  static const String isEnabled = 'sleep_auto_tracking_enabled';
  static const String activeSessionId = 'sleep_active_session_id';
  static const String activeSessionStartMs = 'sleep_active_session_start_ms';
  static const String sensitivityProfile = 'sleep_sensitivity_profile';
  static const String napModeEnabled = 'sleep_nap_mode_enabled';
  static const String nightWindowStart = 'sleep_night_window_start_hour';
  static const String nightWindowEnd = 'sleep_night_window_end_hour';
  static const String sleepTargetHours = 'sleep_target_hours';
  static const String trackingMode = 'sleep_tracking_mode';
  static const String morningWakeOnsetMs = 'sleep_morning_wake_onset_ms';
}

class SleepDetectionService {
  /// Called in the isolate running the detection loop (normally the
  /// background service) when a night's sleep of 30+ minutes ends.
  static void Function(SleepFinishedEvent event)? onSleepFinished;

  final SleepRepository _repository;
  final SleepStateMachine _stateMachine;
  final Battery _battery = Battery();

  // ─── Internal state ──────────────────────────────────────────────────────

  Timer? _minuteTimer;
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<PedestrianStatus>? _pedestrianSubscription;

  /// Accumulates accelerometer samples during the 12-second burst window.
  final List<double> _magnitudeSamples = [];

  /// Accumulates gyroscope samples during the same burst window as the
  /// accelerometer. Piggybacks on the already-open sensor burst, so this
  /// adds negligible extra battery cost while feeding the position
  /// estimator and confidence scorer real rotation data instead of the
  /// always-zero default.
  final List<double> _gyroSamples = [];

  /// EMA-smoothed gyroscope magnitude. Reset before each burst.
  double _gyroEmaSmoothed = -1.0;

  /// Rolling window of per-minute average magnitudes (last 10 minutes).
  /// Exposed via [averageMotion] for trend analysis without I/O.
  final List<double> _motionWindow = [];

  /// Maximum number of per-minute entries retained in [_motionWindow].
  static const int _motionWindowMaxSize = 10;

  /// EMA smoothing factor (alpha). Lower = heavier smoothing.
  /// 0.15 attenuates single jolts (drop, vibration) by ~85%.
  static const double _emaAlpha = 0.15;

  /// Current EMA-smoothed magnitude. Updated sample-by-sample during each
  /// accelerometer burst. Seed is reset to -1 (uninitialised) before each burst.
  double _emaSmoothed = -1.0;

  /// Rolling average of the last [_motionWindowMaxSize] per-minute motion magnitudes.
  /// Returns 0.0 if no data is available yet.
  double get averageMotion {
    if (_motionWindow.isEmpty) return 0.0;
    return _motionWindow.reduce((a, b) => a + b) / _motionWindow.length;
  }

  /// Trend slope of the rolling motion window: negative = declining (good for sleep),
  /// positive = increasing (likely waking up). Returns 0.0 when < 3 data points.
  double get motionTrendSlope {
    final n = _motionWindow.length;
    if (n < 3) return 0.0;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < n; i++) {
      sumX += i;
      sumY += _motionWindow[i];
      sumXY += i * _motionWindow[i];
      sumX2 += i * i.toDouble();
    }
    final denom = n * sumX2 - sumX * sumX;
    if (denom == 0) return 0.0;
    return (n * sumXY - sumX * sumY) / denom;
  }

  /// Latest AR status string from pedometer plugin.
  String _arStatus = 'unknown';

  /// Whether the user walked at any point since the last tick. The plugin
  /// reports 'stopped' a few seconds after the last step, so the status at
  /// the tick alone misses most walking between ticks.
  bool _walkedThisEpoch = false;

  /// Last known charging state, kept when the battery can't be read so a
  /// failed read doesn't look like the phone was unplugged.
  bool _lastIsCharging = false;

  /// Morning wake onset last written to prefs (see [readMorningWakeOnset]).
  DateTime? _savedMorningWakeOnset;

  /// Whether the screen is currently off. Updated from [SleepSignals.events].
  bool _isScreenOff = true;

  /// Screen use and unlocks since the last minute tick (see [_takeEpochInteraction]).
  DateTime? _screenOnSince;
  int _screenOnMsThisEpoch = 0;
  int _unlocksThisEpoch = 0;

  /// Timestamp of the most recent wake event (session end). Used to enforce
  /// a 30-minute minimum gap before a new session can be opened.
  int? _lastWakeTimeMs;

  /// Minimum milliseconds that must elapse after a wake before starting a new
  /// session. Prevents session fragmentation from brief roll-overs.
  static const int _minSessionGapMs = 30 * 60 * 1000; // 30 minutes

  /// The ID of the ongoing auto sleep session, persisted across app restarts.
  String? _activeSessionId;
  int? _activeSessionStartMs;

  // ── Phase 3: Pattern Profile & Position ──────────────────────────────────

  /// Learned user sleep pattern profile. Null until loaded or first session completes.
  SleepPatternProfile? _patternProfile;

  /// Most recent phone position estimate from the last state machine tick.
  PhonePositionEstimate _currentPhonePosition = PhonePositionEstimate.unknown;

  /// Exposed for the diagnostics page to display the current phone position.
  PhonePositionEstimate get estimatedPhonePosition => _currentPhonePosition;

  // Estimated battery drain per hour in foreground (rough estimate for diagnostics).
  // This must be measured on real devices as it varies significantly by OEM.
  // Initial strategy uses burst sampling to limit drain.

  // ── Epoch tracking ───────────────────────────────────────────────────────

  /// In-memory rolling list of the last 10 persisted epochs.
  final List<SleepEpoch> _recentEpochs = [];
  static const int _maxRecentEpochs = 10;

  /// Buffers candidate 60-second epochs during the `possibleSleep` state so that
  /// when `Sleeping` is confirmed, all initial onset epochs are persisted into SQLite.
  final List<SleepEpoch> _candidateOnsetEpochs = [];

  /// Start time of the current epoch window (set at session start + each tick).
  DateTime? _epochStartTime;

  StreamSubscription<SleepSignalEvent>? _screenSubscription;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// Active auto session ID (null if awake / no session).
  String? get activeSessionId => _activeSessionId;

  /// Active auto session start timestamp in ms.
  int? get activeSessionStartMs => _activeSessionStartMs;

  /// Number of buffered candidate epochs during `possibleSleep`.
  int get candidateOnsetEpochsCount => _candidateOnsetEpochs.length;

  /// Underlying state machine instance.
  SleepStateMachine get stateMachine => _stateMachine;

  SleepDetectionService({
    SleepRepository? repository,
    SleepStateMachine? stateMachine,
    SleepDetectionConfig config = const SleepDetectionConfig(),
  })  : _repository = repository ?? SleepRepository(),
        _stateMachine = stateMachine ?? SleepStateMachine(config: config);

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  /// Starts the detection service. Should be called once per night window entry
  /// (or at app start if already in night window). Idempotent.
  Future<void> start() async {
    if (_isRunning) return;
    await _repository.init();
    await SleepDetectionLogger().init();
    await SensorCapabilityManager.initialize();
    SleepDetectionLogger().logEvent('🟢 Sleep auto-tracking service started', level: 'INFO');
    // Phase 3: load the user's learned sleep pattern profile.
    _patternProfile = await SleepPatternLearner.load();
    if (_patternProfile != null) {
      SleepDetectionLogger().logEvent(
        '📊 Pattern profile loaded: bedtime=${_patternProfile!.bedtimeLabel} sessions=${_patternProfile!.sessionCount}',
        level: 'INFO',
      );
    }
    await _restoreSessionFromPrefs();
    _startPedestrianStream();
    await _startScreenEventListener();
    _scheduleMachineCheck();
    _isRunning = true;
  }

  /// Stops the service cleanly. Should be called at night window end or
  /// when the user disables auto-tracking.
  Future<void> stop() async {
    if (!_isRunning) return;
    SleepDetectionLogger().logEvent('🔴 Sleep auto-tracking service stopped', level: 'INFO');

    // Auto-close any open session before shutting down.
    // Without this, sessions get orphaned with wakeTimeMs = NULL and show
    // as "Ongoing" forever whenever the service stops at night window end.
    if (_activeSessionId != null) {
      SleepDetectionLogger().logEvent(
        '📤 Auto-closing session on service stop: $_activeSessionId',
        level: 'INFO',
      );
      await _finishSession(DateTime.now(), ClosureReason.serviceStopped);
    }

    _minuteTimer?.cancel();
    _minuteTimer = null;
    await _accelSubscription?.cancel();
    _accelSubscription = null;
    await _gyroSubscription?.cancel();
    _gyroSubscription = null;
    await _pedestrianSubscription?.cancel();
    _pedestrianSubscription = null;
    await _screenSubscription?.cancel();
    _screenSubscription = null;
    _magnitudeSamples.clear();
    _gyroSamples.clear();
    _motionWindow.clear();
    _emaSmoothed = -1.0;
    _gyroEmaSmoothed = -1.0;
    _isRunning = false;
  }

  // ─── Sensitivity & Nap Mode Settings ─────────────────────────────────────

  static Future<SensitivityProfile> getSensitivityProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_PrefKeys.sensitivityProfile) ?? SensitivityProfile.normal.index;
    return SensitivityProfile.values[index.clamp(0, SensitivityProfile.values.length - 1)];
  }

  static Future<void> setSensitivityProfile(SensitivityProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefKeys.sensitivityProfile, profile.index);
  }

  static Future<bool> isNapModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_PrefKeys.napModeEnabled) ?? false;
  }

  static Future<void> setNapModeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefKeys.napModeEnabled, value);
  }

  // ─── Tracking Mode (Hybrid vs Usage-Based) ───────────────────────────────

  static Future<SleepTrackingMode> getTrackingMode() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString(_PrefKeys.trackingMode);
    return SleepTrackingMode.fromString(val);
  }

  static Future<void> setTrackingMode(SleepTrackingMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefKeys.trackingMode, mode.name);
  }

  // ─── Enable / Disable (user-facing opt-in) ────────────────────────────────

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_PrefKeys.isEnabled) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefKeys.isEnabled, value);
  }

  // ─── Night Window & Target Hours Settings ─────────────────────────────────

  /// Returns the custom night window start hour (default: 21 = 9 PM).
  static Future<int> getNightWindowStartHour() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_PrefKeys.nightWindowStart) ?? 21;
  }

  static Future<void> setNightWindowStartHour(int hour) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefKeys.nightWindowStart, hour);
  }

  /// Returns the custom night window end hour (default: 9 = 9 AM).
  static Future<int> getNightWindowEndHour() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_PrefKeys.nightWindowEnd) ?? 9;
  }

  static Future<void> setNightWindowEndHour(int hour) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefKeys.nightWindowEnd, hour);
  }

  /// Returns the custom sleep target hours (default: 8.0).
  static Future<double> getSleepTargetHours() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_PrefKeys.sleepTargetHours) ?? 8.0;
  }

  static Future<void> setSleepTargetHours(double hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_PrefKeys.sleepTargetHours, hours);
  }

  // ─── Screen & Unlock Signals ──────────────────────────────────────────────

  void _onScreenOn(DateTime at) {
    if (!_isScreenOff) return;
    _isScreenOff = false;
    _screenOnSince = at;
    _stateMachine.onScreenOn(at);
    SleepDetectionLogger().logEvent('📱 Screen turned ON', level: 'SENSOR');
  }

  void _onScreenOff(DateTime at) {
    if (_isScreenOff) return;
    _isScreenOff = true;
    _screenOnMsThisEpoch += at.difference(_screenOnSince!).inMilliseconds;
    _screenOnSince = null;
    SleepDetectionLogger().logEvent('🌑 Screen turned OFF', level: 'SENSOR');
  }

  void _onUnlocked() {
    _unlocksThisEpoch++;
    SleepDetectionLogger().logEvent('🔓 Phone unlocked', level: 'SENSOR');
  }

  /// Screen-on seconds and unlocks since the previous tick; starts a new count.
  ({int screenOnSecs, int unlocks}) _takeEpochInteraction(DateTime now) {
    var onMs = _screenOnMsThisEpoch;
    if (_screenOnSince != null) {
      onMs += now.difference(_screenOnSince!).inMilliseconds;
      _screenOnSince = now;
    }
    final taken = (screenOnSecs: (onMs / 1000).round().clamp(0, 60), unlocks: _unlocksThisEpoch);
    _screenOnMsThisEpoch = 0;
    _unlocksThisEpoch = 0;
    return taken;
  }

  /// Room light and proximity for this minute. Unavailable sensors read as
  /// 0 lux / not near, which is what [SensorSnapshot] expects.
  Future<({double lux, bool near})> _readEnvironment() async {
    if (!Platform.isAndroid) return (lux: 0.0, near: false);
    try {
      final (lux, near) = await (SleepSignals.readLight(), SleepSignals.readProximity()).wait
          .timeout(const Duration(seconds: 3));
      return (lux: lux ?? 0.0, near: near ?? false);
    } catch (e) {
      SleepDetectionLogger().logEvent('⚠️ Light/proximity read failed: $e', level: 'WARN');
      return (lux: 0.0, near: false);
    }
  }

  /// Screen and unlock events come from the sleep_signals plugin (Android only).
  Future<void> _startScreenEventListener() async {
    await _screenSubscription?.cancel();
    if (!Platform.isAndroid) return;

    final state = await SleepSignals.currentState();
    if (state.screenOn) _onScreenOn(DateTime.now());

    _screenSubscription = SleepSignals.events.listen((event) {
      final now = DateTime.now();
      switch (event) {
        case SleepSignalEvent.screenOn:
          _onScreenOn(now);
        case SleepSignalEvent.screenOff:
          _onScreenOff(now);
        case SleepSignalEvent.unlocked:
          _onUnlocked();
      }
    });
  }

  // ─── Internal: Per-minute check ──────────────────────────────────────────

  void _scheduleMachineCheck() {
    // Fire immediately, then every 60 seconds.
    _runCheck();
    _minuteTimer = Timer.periodic(const Duration(seconds: 60), (_) => _runCheck());
  }

  Future<void> _runCheck() async {
    final now = DateTime.now();
    final interaction = _takeEpochInteraction(now);
    await _dropSessionClosedElsewhere();
    final isNap = await isNapModeEnabled();
    final nightStart = await getNightWindowStartHour();
    final nightEnd = await getNightWindowEndHour();
    final inNightWindow = _isInNightWindowSync(now, nightStart, nightEnd, isNap);

    // ── Sync live settings into the state machine ────────────────────────────
    // The state machine config is immutable at construction time. We push updated
    // values from SharedPreferences each tick so the night window hours and nap
    // mode are always current. Without this, the machine always uses its stale
    // constructor defaults, causing night sessions to never be detected and nap
    // mode to fire incorrectly.
    _stateMachine.updateConfig(SleepDetectionConfig(
      isNapMode: isNap,
      nightWindowStartHour: nightStart,
      nightWindowEndHour: nightEnd,
    ));

    if (!isNap && !inNightWindow) {
      // A session still open when the night window ends: the user got up
      // without the phone confirming it. Their last phone activity of the
      // morning is the best wake time; without any, the window end.
      if (_activeSessionId != null) {
        SleepDetectionLogger().logEvent(
          '☀️ Night window ended — auto-finalizing morning session: $_activeSessionId',
          level: 'INFO',
        );
        await _finishSession(_stateMachine.morningWakeOnset ?? now, ClosureReason.normalWake);
      }
      // Daytime idle standby: Keep timer alive so tracking begins automatically at night window start
      return;
    }

    // ── Safety timeout: max session duration 14 hours (840 minutes) ─────
    if (_activeSessionId != null) {
      final elapsedMins = (now.millisecondsSinceEpoch - _activeSessionStartMs!) ~/ 60000;
      if (elapsedMins >= SleepSession.maxSessionDurationMinutes) {
        SleepDetectionLogger().logEvent(
          '⚠️ Session exceeded ${SleepSession.maxSessionDurationMinutes ~/ 60}h safety limit — auto-closing',
          level: 'WARN',
        );
        await _finishSession(now, ClosureReason.safetyTimeout);
        return;
      }
    }

    final mode = await getTrackingMode();

    // ── Adaptive Sensing Lifecycle ──────────────────────────────────────────
    // Stage A: Low-power watch (Awake & Screen is actively being used) -> 0s burst
    // Stage B: Possible Sleep onset -> 12s burst / 60s
    // Stage C: Confirmed Sleeping -> 4s burst (75% lower sensor power)
    // Stage D: Possible Wake -> 12s burst / 60s
    final isScreenActive = !_isScreenOff;
    final currentState = _stateMachine.currentState;
    final isStageALowPower = currentState == SleepState.awake && isScreenActive;

    final burstDurationSecs = (mode == SleepTrackingMode.usageBased || isStageALowPower)
        ? 0
        : (currentState == SleepState.sleeping ? 4 : 12);

    _magnitudeSamples.clear();
    _emaSmoothed = -1.0; // reset EMA seed before each burst
    _gyroSamples.clear();
    _gyroEmaSmoothed = -1.0;

    if (burstDurationSecs > 0) {
      await _startAccelerometerBurst();
      // Gyroscope piggybacks on the same open burst window — no extra
      // wake-lock or additional battery cost beyond the accelerometer burst
      // that's already running.
      _startGyroscopeBurst();
      await Future.delayed(Duration(seconds: burstDurationSecs));
      await _accelSubscription?.cancel();
      _accelSubscription = null;
      await _gyroSubscription?.cancel();
      _gyroSubscription = null;
    }

    // ── Step 2: Compute motion statistics ─────────────────────────────────
    double magnitude = 0.0;
    double variance = 0.0;

    if (_magnitudeSamples.isNotEmpty) {
      // EMA final value = smoothed signal from the burst.
      magnitude = _emaSmoothed > 0 ? _emaSmoothed : _computeMean(_magnitudeSamples);
      // Variance on the raw samples to preserve high-frequency jitter signal.
      final rawMean = _computeMean(_magnitudeSamples);
      variance = _computeStdDev(_magnitudeSamples, rawMean);
    }

    double gyroMagnitude = 0.0;
    double gyroVariance = 0.0;
    if (_gyroSamples.isNotEmpty) {
      gyroMagnitude = _gyroEmaSmoothed > 0 ? _gyroEmaSmoothed : _computeMean(_gyroSamples);
      final rawGyroMean = _computeMean(_gyroSamples);
      gyroVariance = _computeStdDev(_gyroSamples, rawGyroMean);
    }

    // Push this minute's EMA magnitude into the rolling motionWindow.
    _motionWindow.add(magnitude);
    if (_motionWindow.length > _motionWindowMaxSize) {
      _motionWindow.removeAt(0);
    }

    // ── Step 3: Gather other signals ──────────────────────────────────────
    final batteryState = await _battery.batteryState.timeout(
      const Duration(seconds: 2),
      onTimeout: () => BatteryState.unknown,
    );
    // On the charger counts even when a charge limit has paused charging.
    final isCharging = switch (batteryState) {
      BatteryState.charging || BatteryState.full || BatteryState.connectedNotCharging => true,
      BatteryState.discharging => false,
      BatteryState.unknown => _lastIsCharging,
    };
    _lastIsCharging = isCharging;
    final environment = await _readEnvironment();
    final activity = _walkedThisEpoch ? 'walking' : _arStatus;
    _walkedThisEpoch = false;

    // ── Step 4: Build snapshot (now includes rolling average + trend) ─────
    final snapshot = SensorSnapshot(
      motionMagnitude: magnitude,
      motionVariance: variance,
      rollingAverageMotion: averageMotion,
      motionTrendSlope: motionTrendSlope,
      gyroMagnitude: gyroMagnitude,
      gyroVariance: gyroVariance,
      isScreenOff: _isScreenOff,
      screenOnDurationSecs: interaction.screenOnSecs,
      unlockCount: interaction.unlocks,
      isCharging: isCharging,
      ambientLux: environment.lux,
      proximityNear: environment.near,
      activityRecognition: activity,
      timestamp: now,
    );

    // ── Step 5: Run state machine with circadian weight ───────────────────
    final priorState = _stateMachine.currentState;
    final circadianWeight = SleepPatternLearner.circadianWeight(now, _patternProfile);
    // Cap confidence to what the device's actual sensor set can support —
    // e.g. a phone without a gyroscope shouldn't be able to reach the same
    // peak confidence as one with full sensor coverage.
    final confidenceCeiling = SensorCapabilityManager.current?.confidenceCeiling ?? 100;
    final result = _stateMachine.evaluate(
      snapshot,
      circadianWeight: circadianWeight,
      confidenceCeiling: confidenceCeiling,
    );
    // Update phone position from the result for diagnostics exposure.
    if (result.phonePosition != null) {
      _currentPhonePosition = result.phonePosition!;
    }
    await _saveMorningWakeOnset(_stateMachine.morningWakeOnset);

    // Log the sensor evaluation for live diagnostics.
    SleepDetectionLogger().logSensorSnapshot(
      snapshot: snapshot,
      result: result,
      currentStateName: priorState.name,
    );

    if (result.newState != priorState) {
      SleepDetectionLogger().logStateTransition(
        fromState: priorState,
        toState: result.newState,
        confidenceScore: result.confidenceScore,
        reason: result.debugReason ?? '',
      );
    }

    // ── Step 6: Handle state transitions & epoch persistence ────────────────
    final epochStart = _epochStartTime ?? now.subtract(const Duration(seconds: 60));
    final epochEnd = now;

    // Create current epoch snapshot model
    final currentEpoch = SleepEpoch(
      id: 'epoch_temp_${epochStart.millisecondsSinceEpoch}',
      sessionId: _activeSessionId ?? 'candidate',
      startTimeMs: epochStart.millisecondsSinceEpoch,
      endTimeMs: epochEnd.millisecondsSinceEpoch,
      movementScore: snapshot.effectiveMovementScore,
      movementVariance: snapshot.motionVariance,
      movementTrend: snapshot.motionTrendSlope,
      rotationScore: snapshot.gyroMagnitude > 0
          ? (100 - (snapshot.gyroMagnitude / 0.30 * 100)).round().clamp(0, 100)
          : null,
      screenOnDurationSecs: snapshot.screenOnDurationSecs,
      screenActivationCount: snapshot.screenOnDurationSecs > 0 ? 1 : 0,
      unlockCount: snapshot.unlockCount > 0 ? snapshot.unlockCount : null,
      interactionCount: snapshot.touchEventCount > 0 ? snapshot.touchEventCount : null,
      ambientLux: snapshot.ambientLux > 0 ? snapshot.ambientLux : null,
      proximityNear: snapshot.proximityNear ? true : null,
      isCharging: snapshot.isCharging,
      batteryLevel: snapshot.batteryLevel >= 0 ? snapshot.batteryLevel : null,
      activityState: snapshot.activityRecognition,
      dataQuality: _magnitudeSamples.length >= 30
          ? DataQuality.high
          : (_magnitudeSamples.isNotEmpty ? DataQuality.medium : DataQuality.low),
    );

    await _handleStateTransition(
      result,
      now,
      currentEpoch: currentEpoch,
      snapshot: snapshot,
      epochStart: epochStart,
      epochEnd: epochEnd,
      isNap: isNap,
    );

    // Advance the epoch window start to now.
    _epochStartTime = now;
  }

  /// Performs an immediate on-demand diagnostic sample (e.g. 4 seconds burst)
  /// so the user can test and inspect their phone's sensor readings instantly.
  Future<Map<String, dynamic>> performDiagnosticBurst({Duration burstDuration = const Duration(seconds: 4)}) async {
    final now = DateTime.now();
    _magnitudeSamples.clear();
    _emaSmoothed = -1.0;
    _gyroSamples.clear();
    _gyroEmaSmoothed = -1.0;
    await _startAccelerometerBurst();
    _startGyroscopeBurst();
    await Future.delayed(burstDuration);
    await _accelSubscription?.cancel();
    _accelSubscription = null;
    await _gyroSubscription?.cancel();
    _gyroSubscription = null;

    double magnitude = 0.0;
    double variance = 0.0;
    if (_magnitudeSamples.isNotEmpty) {
      magnitude = _emaSmoothed > 0 ? _emaSmoothed : _computeMean(_magnitudeSamples);
      final rawMean = _computeMean(_magnitudeSamples);
      variance = _computeStdDev(_magnitudeSamples, rawMean);
    }

    double gyroMagnitude = 0.0;
    double gyroVariance = 0.0;
    if (_gyroSamples.isNotEmpty) {
      gyroMagnitude = _gyroEmaSmoothed > 0 ? _gyroEmaSmoothed : _computeMean(_gyroSamples);
      final rawGyroMean = _computeMean(_gyroSamples);
      gyroVariance = _computeStdDev(_gyroSamples, rawGyroMean);
    }

    final batteryState = await _battery.batteryState.timeout(
      const Duration(seconds: 2),
      onTimeout: () => BatteryState.unknown,
    );
    final isCharging = batteryState == BatteryState.charging || batteryState == BatteryState.full;

    final snapshot = SensorSnapshot(
      motionMagnitude: magnitude,
      motionVariance: variance,
      rollingAverageMotion: averageMotion > 0 ? averageMotion : magnitude,
      motionTrendSlope: motionTrendSlope,
      gyroMagnitude: gyroMagnitude,
      gyroVariance: gyroVariance,
      isScreenOff: _isScreenOff,
      isCharging: isCharging,
      activityRecognition: _arStatus,
      timestamp: now,
    );

    final confidenceCeiling = SensorCapabilityManager.current?.confidenceCeiling ?? 100;
    final result = _stateMachine.evaluate(snapshot, confidenceCeiling: confidenceCeiling);
    SleepDetectionLogger().logSensorSnapshot(
      snapshot: snapshot,
      result: result,
      currentStateName: _stateMachine.currentState.name,
    );

    return {
      'snapshot': snapshot,
      'result': result,
      'samplesCount': _magnitudeSamples.length,
    };
  }

  /// Builds a persistable [SleepEpoch] for the active session from the
  /// computed [currentEpoch] snapshot and this minute's epoch window.
  /// Factored out of [_handleStateTransition], which previously duplicated
  /// this exact 16-field construction across four branches — a maintenance
  /// hazard where one branch could silently drift from the others.
  SleepEpoch _epochForActiveSession(
    DateTime epochStart,
    DateTime epochEnd,
    SleepEpoch currentEpoch,
  ) {
    return SleepEpoch(
      id: 'epoch_${_activeSessionId}_${epochStart.millisecondsSinceEpoch}',
      sessionId: _activeSessionId!,
      startTimeMs: epochStart.millisecondsSinceEpoch,
      endTimeMs: epochEnd.millisecondsSinceEpoch,
      movementScore: currentEpoch.movementScore,
      movementVariance: currentEpoch.movementVariance,
      movementTrend: currentEpoch.movementTrend,
      rotationScore: currentEpoch.rotationScore,
      screenOnDurationSecs: currentEpoch.screenOnDurationSecs,
      screenActivationCount: currentEpoch.screenActivationCount,
      unlockCount: currentEpoch.unlockCount,
      interactionCount: currentEpoch.interactionCount,
      ambientLux: currentEpoch.ambientLux,
      proximityNear: currentEpoch.proximityNear,
      isCharging: currentEpoch.isCharging,
      batteryLevel: currentEpoch.batteryLevel,
      activityState: currentEpoch.activityState,
      dataQuality: currentEpoch.dataQuality,
    );
  }

  Future<void> _handleStateTransition(
    StateMachineResult result,
    DateTime now, {
    required SleepEpoch currentEpoch,
    required SensorSnapshot snapshot,
    required DateTime epochStart,
    required DateTime epochEnd,
    bool isNap = false,
  }) async {
    switch (result.newState) {
      case SleepState.possibleSleep:
        // Buffer this candidate onset epoch in memory
        _candidateOnsetEpochs.add(currentEpoch);
        break;

      case SleepState.sleeping:
        // Newly entered Sleeping state: start a new session if none active.
        if (_activeSessionId == null) {
          // ── Minimum session gap guard ────────────────────────────────────
          if (_lastWakeTimeMs != null) {
            final gapMs = now.millisecondsSinceEpoch - _lastWakeTimeMs!;
            if (gapMs < _minSessionGapMs) {
              // Too soon — stay silent and let the state machine continue counting.
              break;
            }
          }
          final onsetTime = result.possibleSleepStartTime ?? now;
          final mode = await getTrackingMode();
          _activeSessionId = await _repository.startAutoSession(
            sleepStartMs: onsetTime.millisecondsSinceEpoch,
            confidenceScore: result.confidenceScore,
            isNap: isNap,
            trackingMode: mode,
          );
          _activeSessionStartMs = onsetTime.millisecondsSinceEpoch;
          _recentEpochs.clear();
          await _persistActiveSession();

          SleepDetectionLogger().logSessionCreated(
            sessionId: _activeSessionId!,
            onsetTime: onsetTime,
            bufferedEpochs: _candidateOnsetEpochs.length,
          );

          // Batch insert all buffered candidate onset epochs
          if (_candidateOnsetEpochs.isNotEmpty) {
            final remappedEpochs = _candidateOnsetEpochs.map((e) => SleepEpoch(
              id: 'epoch_${_activeSessionId}_${e.startTimeMs}',
              sessionId: _activeSessionId!,
              startTimeMs: e.startTimeMs,
              endTimeMs: e.endTimeMs,
              movementScore: e.movementScore,
              movementVariance: e.movementVariance,
              movementTrend: e.movementTrend,
              rotationScore: e.rotationScore,
              screenOnDurationSecs: e.screenOnDurationSecs,
              screenActivationCount: e.screenActivationCount,
              unlockCount: e.unlockCount,
              interactionCount: e.interactionCount,
              ambientLux: e.ambientLux,
              proximityNear: e.proximityNear,
              isCharging: e.isCharging,
              batteryLevel: e.batteryLevel,
              activityState: e.activityState,
              dataQuality: e.dataQuality,
            )).toList();
            await _repository.saveEpochs(remappedEpochs);
            _candidateOnsetEpochs.clear();
          }

          // Save current minute's epoch
          final sessionEpoch = _epochForActiveSession(epochStart, epochEnd, currentEpoch);
          await _repository.saveEpoch(sessionEpoch);
          _recentEpochs.add(sessionEpoch);

          SleepDetectionLogger().logEpochSaved(
            sessionId: _activeSessionId!,
            timestamp: now,
            movementScore: snapshot.effectiveMovementScore,
            quality: sessionEpoch.dataQuality.name.toUpperCase(),
          );
        } else {
          // Ongoing session: save current minute's epoch
          final sessionEpoch = _epochForActiveSession(epochStart, epochEnd, currentEpoch);
          await _repository.saveEpoch(sessionEpoch);
          _recentEpochs.add(sessionEpoch);
          if (_recentEpochs.length > _maxRecentEpochs) _recentEpochs.removeAt(0);

          SleepDetectionLogger().logEpochSaved(
            sessionId: _activeSessionId!,
            timestamp: now,
            movementScore: snapshot.effectiveMovementScore,
            quality: sessionEpoch.dataQuality.name.toUpperCase(),
          );
        }
        break;

      case SleepState.possibleWake:
        // Record possible wake epoch (brief awakening during sleep)
        if (_activeSessionId != null) {
          final sessionEpoch = _epochForActiveSession(epochStart, epochEnd, currentEpoch);
          await _repository.saveEpoch(sessionEpoch);
          _recentEpochs.add(sessionEpoch);
          if (_recentEpochs.length > _maxRecentEpochs) _recentEpochs.removeAt(0);

          SleepDetectionLogger().logEpochSaved(
            sessionId: _activeSessionId!,
            timestamp: now,
            movementScore: snapshot.effectiveMovementScore,
            quality: sessionEpoch.dataQuality.name.toUpperCase(),
          );
        }
        break;

      case SleepState.awake:
        _candidateOnsetEpochs.clear();
        // Returned to Awake: finalize active session.
        if (_activeSessionId != null) {
          // 1. Persist the final wake confirmation epoch
          final finalEpoch = _epochForActiveSession(epochStart, epochEnd, currentEpoch);
          await _repository.saveEpoch(finalEpoch);

          // 2. Finalize session record, ending when the wake bout began
          // (a session is only open here after Sleeping → PossibleWake).
          final wakeTime = result.wakeOnsetTime!;
          final sessionId = _activeSessionId!;
          final sleepStart = DateTime.fromMillisecondsSinceEpoch(_activeSessionStartMs!);
          final durMinutes = ((wakeTime.millisecondsSinceEpoch - _activeSessionStartMs!) / 60000).round().clamp(0, 1440);
          SleepDetectionLogger().logSessionFinalized(
            sessionId: sessionId,
            reason: ClosureReason.normalWake.name.toUpperCase(),
            durationMinutes: durMinutes,
          );
          await _finishSession(wakeTime, ClosureReason.normalWake);

          // 3. Morning summary for the host app (if session was >= 30 mins)
          if (durMinutes >= 30) {
            final estimatedScore = math.min(100, math.max(30, (durMinutes / 480.0 * 85 + 15).round()));
            try {
              onSleepFinished?.call(SleepFinishedEvent(
                sessionId: sessionId,
                sleepStart: sleepStart,
                wakeTime: wakeTime,
                durationMinutes: durMinutes,
                sleepScore: estimatedScore,
              ));
            } catch (_) {}
          }
        }
        break;
    }
  }

  /// Ends the active session at [wakeTime] and resets detection to Awake, so
  /// the next night starts from a clean state instead of still "sleeping".
  Future<void> _finishSession(DateTime wakeTime, ClosureReason reason) async {
    await _repository.endAutoSession(
      id: _activeSessionId!,
      wakeTimeMs: wakeTime.millisecondsSinceEpoch,
      sleepStartMs: _activeSessionStartMs!,
      closureReason: reason,
    );
    await _resetAfterSession(wakeTime.millisecondsSinceEpoch);
    _updatePatternProfile();
  }

  Future<void> _resetAfterSession(int wakeTimeMs) async {
    _lastWakeTimeMs = wakeTimeMs;
    _activeSessionId = null;
    _activeSessionStartMs = null;
    _recentEpochs.clear();
    _epochStartTime = null;
    _stateMachine.restoreState(state: SleepState.awake);
    await _clearActiveSessionPrefs();
    await _saveMorningWakeOnset(null);
  }

  /// Opening the app in the morning ends the session there
  /// (SleepRecoveryManager.closeSessionIfAwake). Stop tracking it here too,
  /// otherwise it would be ended a second time with a later wake time.
  Future<void> _dropSessionClosedElsewhere() async {
    final id = _activeSessionId;
    if (id == null) return;
    final session = await _repository.getSessionById(id);
    if (session != null && session.isOngoing) return;
    SleepDetectionLogger().logEvent('📲 Session $id was ended in the app — tracking reset', level: 'INFO');
    await _resetAfterSession(session?.wakeTimeMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  // ─── Accelerometer ──────────────────────────────────────────────────────────

  Future<void> _startAccelerometerBurst() async {
    // sensors_plus 4.0+ API: accelerometerEventStream with explicit sampling interval.
    // SensorInterval.normal ≈ 200ms → ~60 samples in 12 seconds.
    // We do NOT use SensorInterval.fastest (100Hz) to conserve battery.
    _accelSubscription = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((AccelerometerEvent event) {
      // Compute vector magnitude minus gravity (1g = 9.8 m/s²).
      final rawMagnitude = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      // Convert m/s² to g and subtract the gravitational component.
      final magnitudeG = rawMagnitude / 9.81;
      final delta = (magnitudeG - 1.0).abs();

      // ── EMA smoothing ───────────────────────────────────────────────────
      // On the first sample, seed the EMA with the raw value.
      // alpha = 0.15: new sample contributes 15%, history 85%.
      // This heavily attenuates single jolts (drop, pocket vibration) while
      // still tracking genuine sustained motion within seconds.
      if (_emaSmoothed < 0) {
        _emaSmoothed = delta;
      } else {
        _emaSmoothed = _emaAlpha * delta + (1 - _emaAlpha) * _emaSmoothed;
      }

      _magnitudeSamples.add(delta); // raw samples kept for variance
    });
  }

  /// Samples the gyroscope for the same duration as the accelerometer burst.
  /// Feeds [PhonePositionEstimator] and the confidence scorer real rotation
  /// data — without this, gyroMagnitude/gyroVariance silently defaulted to
  /// 0.0, which reads identically to "confirmed perfectly still" and biased
  /// every score toward sleep regardless of actual phone handling.
  void _startGyroscopeBurst() {
    _gyroSubscription = gyroscopeEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((GyroscopeEvent event) {
      final rawMagnitude = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      if (_gyroEmaSmoothed < 0) {
        _gyroEmaSmoothed = rawMagnitude;
      } else {
        _gyroEmaSmoothed = _emaAlpha * rawMagnitude + (1 - _emaAlpha) * _gyroEmaSmoothed;
      }

      _gyroSamples.add(rawMagnitude);
    }, onError: (_) {
      // Device has no gyroscope, or it failed mid-burst — gyroMagnitude/
      // gyroVariance simply stay at their accumulated (possibly empty) state.
    });
  }

  // ─── Phase 3: Pattern Profile Update ─────────────────────────────────────

  /// Loads all completed sessions and rebuilds the user's sleep pattern profile.
  /// Called asynchronously after each session ends so it never blocks detection.
  Future<void> _updatePatternProfile() async {
    try {
      final sessions = await _repository.getRecentSessions(days: 365);
      final updated = await SleepPatternLearner.updateAndSave(sessions);
      if (updated != null) {
        _patternProfile = updated;
        SleepDetectionLogger().logEvent(
          '📊 Pattern profile updated: bedtime=${updated.bedtimeLabel} '
          'wake=${updated.wakeLabel} sessions=${updated.sessionCount} '
          'confidence=${(updated.confidence * 100).round()}%',
          level: 'INFO',
        );
      }
    } catch (_) {
      // Non-fatal — detection continues even if profile update fails.
    }
  }

  // ─── Pedestrian Status (Activity Recognition) ─────────────────────────────

  void _startPedestrianStream() {
    _pedestrianSubscription?.cancel();
    _pedestrianSubscription = Pedometer.pedestrianStatusStream.listen(
      (PedestrianStatus event) {
        // Pedometer plugin wraps Android Activity Recognition API.
        // Status values: 'walking', 'stopped' (mapped to 'still' by the plugin).
        _arStatus = event.status == 'stopped' ? 'still' : event.status;
        if (_arStatus == 'walking') _walkedThisEpoch = true;
      },
      onError: (_) {
        _arStatus = 'unknown';
      },
    );
  }

  // ─── SharedPreferences Persistence ───────────────────────────────────────

  /// Restores active session from prefs so a service restart mid-session
  /// doesn't create a duplicate entry.
  Future<void> _restoreSessionFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _activeSessionId = prefs.getString(_PrefKeys.activeSessionId);
    final ms = prefs.getInt(_PrefKeys.activeSessionStartMs);
    _activeSessionStartMs = ms;

    // Validate: if the persisted session no longer exists in DB, clear it.
    if (_activeSessionId != null && _activeSessionStartMs != null) {
      final ongoing = await _repository.getOngoingSession();
      if (ongoing == null || ongoing.id != _activeSessionId) {
        _activeSessionId = null;
        _activeSessionStartMs = null;
        await _clearActiveSessionPrefs();
      } else {
        // Restore state machine to Sleeping so subsequent wake evaluations cleanly trigger transition to Awake!
        _stateMachine.restoreState(
          state: SleepState.sleeping,
          sleepStartTime: DateTime.fromMillisecondsSinceEpoch(_activeSessionStartMs!),
          morningWakeOnset: _savedMorningWakeOnset = await readMorningWakeOnset(),
        );
        SleepDetectionLogger().logEvent(
          '🔄 Restored active sleep session ($_activeSessionId) into state machine (Sleeping)',
          level: 'INFO',
        );
      }
    }
  }

  Future<void> _persistActiveSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (_activeSessionId != null) {
      await prefs.setString(_PrefKeys.activeSessionId, _activeSessionId!);
    }
    if (_activeSessionStartMs != null) {
      await prefs.setInt(_PrefKeys.activeSessionStartMs, _activeSessionStartMs!);
    }
  }

  /// When the user got up this morning according to the overnight tracker
  /// (see [SleepStateMachine.morningWakeOnset]), or null. Written by the
  /// background isolate, so the cached prefs are reloaded first.
  static Future<DateTime?> readMorningWakeOnset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ms = prefs.getInt(_PrefKeys.morningWakeOnsetMs);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Shares the morning wake onset with the app, which may end the session
  /// itself when opened (SleepRecoveryManager.closeSessionIfAwake).
  Future<void> _saveMorningWakeOnset(DateTime? onset) async {
    if (onset == _savedMorningWakeOnset) return;
    final prefs = await SharedPreferences.getInstance();
    if (onset == null) {
      await prefs.remove(_PrefKeys.morningWakeOnsetMs);
    } else {
      await prefs.setInt(_PrefKeys.morningWakeOnsetMs, onset.millisecondsSinceEpoch);
    }
    _savedMorningWakeOnset = onset;
  }

  Future<void> _clearActiveSessionPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_PrefKeys.activeSessionId);
    await prefs.remove(_PrefKeys.activeSessionStartMs);
  }

  // ─── Night Window Helper ─────────────────────────────────────────────

  /// Synchronous night window check using already-fetched hour values.
  /// Avoids redundant SharedPreferences reads when hours are already known.
  bool _isInNightWindowSync(DateTime dt, int startHour, int endHour, bool isNap) {
    if (isNap) return true; // Nap mode: always active
    final h = dt.hour;
    return h >= startHour || h < endHour;
  }

  // ─── Stats Helpers ────────────────────────────────────────────────────────

  double _computeMean(List<double> values) {
    if (values.isEmpty) return 0.0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _computeStdDev(List<double> values, double mean) {
    if (values.length < 2) return 0.0;
    final variance =
        values.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) /
            values.length;
    return math.sqrt(variance);
  }
}
