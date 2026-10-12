/// Pure, I/O-free state machine for automatic sleep detection.
///
/// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///  State transitions:
///
///  Awake ──[onset conditions met]──► PossibleSleep
///  PossibleSleep ──[N min sustained]──► Sleeping   (N = sleepOnsetMinutes, default 25)
///  PossibleSleep ──[interrupted]──► Awake
///  Sleeping ──[motion / screen / unlock / walking]──► PossibleWake
///  PossibleWake ──[M min sustained]──► Awake       (M = wakeConfirmMinutes, default 5)
///  PossibleWake ──[got up: unlock, walking, unplugging the charger or
///                  1 min of screen, outside core night 10 PM–5 AM]──► Awake
///  PossibleWake ──[still again]──► Sleeping        (brief awakening)
///
///  A confirmed wake is dated to when the wake bout began — or, in the
///  morning, to the first sign of getting up since the user last lay still
///  for [SleepStateMachine.backToSleepMinutes] (see [SleepStateMachine.morningWakeOnset]).
/// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///
/// ⚠️ This is motion + screen-state heuristics only.
/// It is a wellness estimate, NOT a clinical or medically validated system.
/// Sleep stages (Deep/REM/Light) are intentionally NOT estimated — the sensor
/// signals available on a consumer phone do not support reliable stage detection
/// without clinical reference hardware.
library;

import 'dart:math' as math;

// ─── Enums ────────────────────────────────────────────────────────────────────

enum SleepState {
  awake,
  possibleSleep,
  sleeping,
  possibleWake,
}

enum SensitivityProfile {
  firmMattress,
  normal,
  softMattressOrPartner,
}

// ─── Phone Position Inference ─────────────────────────────────────────────────

/// Inferred phone position based on motion pattern analysis.
///
/// ⚠️ These are probabilistic inferences from indirect sensor signals, NOT
/// direct knowledge of where the phone is. Multiple corroborating signals
/// are needed to increase confidence. No single signal confirms position.
enum PhonePositionEstimate {
  /// Very low acceleration and very low gyro: phone appears stationary.
  /// Could be on a flat surface (table, mattress, nightstand) — cannot distinguish
  /// between these placements from motion signals alone.
  likelyStationary,

  /// Very low acceleration with occasional micro-gyro variance.
  /// Consistent with a phone resting near soft material (pillow-side).
  /// Combined with low ambient light, increases sleep probability weight.
  likelyStill,

  /// Very low acceleration, proximity obstruction detected, and low ambient light.
  /// Corroborating signals suggest a stationary, covered environment.
  /// Cannot confirm exact placement.
  likelyStationaryCovered,

  /// Moderate-to-high acceleration or rotation: phone appears to be moving.
  /// Likely held in hand, carried in pocket, or being picked up.
  likelyHandheld,

  /// Insufficient signals to infer position.
  unknown,
}

/// Heuristic phone position inferrer from a [SensorSnapshot].
///
/// Returns probabilistic position labels used as one input to the confidence
/// scoring system. Position inference should be treated as a supporting signal,
/// not a definitive conclusion.
class PhonePositionEstimator {
  PhonePositionEstimator._();

  /// Infers phone position from motion magnitude and gyroscope signals.
  ///
  /// Thresholds are initial experimental values; they will vary across
  /// phone models, placements, and surface types. Tune from real-world data.
  static PhonePositionEstimate estimate(SensorSnapshot snap) {
    final m = snap.motionMagnitude;
    final g = snap.gyroMagnitude;
    final gv = snap.gyroVariance;

    // Very low accel + very low gyro: phone appears stationary.
    if (m < 0.06 && g < 0.02) {
      // Gyro variance suggests micro-vibrations (soft surface nearby).
      if (gv > 0.03) return PhonePositionEstimate.likelyStill;
      // Proximity obstruction + low ambient light: corroborating stationary signals.
      if (snap.proximityNear || snap.ambientLux < 10) {
        return PhonePositionEstimate.likelyStationaryCovered;
      }
      return PhonePositionEstimate.likelyStationary;
    }

    // Low accel but moderate gyro: phone being adjusted or held.
    if (m < 0.12 && g > 0.05) return PhonePositionEstimate.likelyHandheld;

    // Moderate–high accel: phone is moving.
    if (m >= 0.12) return PhonePositionEstimate.likelyHandheld;

    return PhonePositionEstimate.unknown;
  }

  /// Returns a confidence adjustment based on the inferred phone position.
  ///
  /// likelyStationary / likelyStill / likelyStationaryCovered:
  ///   Positive adjustment — stationary phone is consistent with sleep.
  ///   Does NOT confirm the user is sleeping.
  /// likelyHandheld: Negative adjustment — active handling is inconsistent with sleep.
  /// unknown: Small negative adjustment — no position information.
  static int confidenceDelta(PhonePositionEstimate pos) {
    switch (pos) {
      case PhonePositionEstimate.likelyStationary:
        return 6;
      case PhonePositionEstimate.likelyStill:
        return 8;
      case PhonePositionEstimate.likelyStationaryCovered:
        return 10;
      case PhonePositionEstimate.likelyHandheld:
        return -15;
      case PhonePositionEstimate.unknown:
        return -5;
    }
  }
}

// ─── Awakening Type ───────────────────────────────────────────────────────────

/// Classification of a PossibleWake event's severity.
enum AwakeningType {
  /// Screen on < 2 min, no unlock, no interaction: notification glance.
  glance,

  /// 2–4 min of wakefulness: brief awakening (normal, does not end sleep).
  briefAwakening,

  /// ≥ 5 min with active interaction: full wake, session ends.
  fullWake,
}

// ─── Configuration ────────────────────────────────────────────────────────────

/// All tuneable thresholds are grouped here with inline rationale.
/// Changing these values changes detection behaviour — do not treat as magic numbers.
class SleepDetectionConfig {
  /// Sensitivity profile for mattress / bed partner motion noise calibration.
  final SensitivityProfile sensitivityProfile;

  /// Whether Daytime Nap Mode is active (allows daytime sleep detection 9 AM - 9 PM).
  final bool isNapMode;

  /// Night window start hour (24-hour). Default 21 = 9 PM.
  /// Below this hour and above [nightWindowEndHour], detection is disabled unless [isNapMode] is true.
  final int nightWindowStartHour;

  /// Night window end hour (24-hour). Default 9 = 9 AM.
  final int nightWindowEndHour;

  /// Minimum consecutive minutes with score ≥ [sleepConfirmThreshold] to
  /// transition PossibleSleep → Sleeping.
  final int sleepOnsetMinutes;

  /// Minimum consecutive minutes with wake signal to transition PossibleWake → Awake.
  final int wakeConfirmMinutes;

  /// Confidence score threshold to enter PossibleSleep. Must be ≥ 65 to confirm.
  final int sleepConfirmThreshold;

  /// Hysteresis band lower bound. Score < 50 dismisses PossibleSleep.
  final int sleepDismissThreshold;

  final int recentUsageWindowMinutes;
  final int recentUsagePenaltyMinutes;

  /// Motion magnitude below this value (in g) is considered "low motion".
  final double lowMotionThreshold;

  /// Motion magnitude above this value triggers PossibleWake logic.
  final double highMotionThreshold;

  final int alarmGapMinutes;

  const SleepDetectionConfig({
    this.sensitivityProfile = SensitivityProfile.normal,
    this.isNapMode = false,
    this.nightWindowStartHour = 21, // 9 PM
    this.nightWindowEndHour = 9, // 9 AM
    this.sleepOnsetMinutes = 25,
    this.wakeConfirmMinutes = 5,
    this.sleepConfirmThreshold = 65,
    this.sleepDismissThreshold = 50,
    this.recentUsageWindowMinutes = 60,
    this.recentUsagePenaltyMinutes = 10,
    this.lowMotionThreshold = 0.08, // g
    this.highMotionThreshold = 0.15, // g
    this.alarmGapMinutes = 30,
  });

  /// Effective low motion threshold based on sensitivity profile calibration.
  double get effectiveLowMotionThreshold {
    switch (sensitivityProfile) {
      case SensitivityProfile.firmMattress:
        return lowMotionThreshold * 0.75; // 0.06g (more strict)
      case SensitivityProfile.softMattressOrPartner:
        return lowMotionThreshold * 1.75; // 0.14g (tolerates partner movement)
      case SensitivityProfile.normal:
        return lowMotionThreshold; // 0.08g
    }
  }

  /// Effective high motion threshold based on sensitivity profile calibration.
  double get effectiveHighMotionThreshold {
    switch (sensitivityProfile) {
      case SensitivityProfile.firmMattress:
        return highMotionThreshold * 0.80; // 0.12g
      case SensitivityProfile.softMattressOrPartner:
        return highMotionThreshold * 1.47; // 0.22g
      case SensitivityProfile.normal:
        return highMotionThreshold; // 0.15g
    }
  }

  /// Effective sleep onset latency minutes (nap mode uses 15 min SOL).
  int get effectiveOnsetMinutesBase => isNapMode ? 15 : sleepOnsetMinutes;
}

// ─── Sensor Snapshot ──────────────────────────────────────────────────────────

/// A single 60-second epoch snapshot consumed by the state machine.
/// All fields are aggregated without I/O — the service layer computes
/// them from raw sensor bursts and passes them in, keeping this class
/// pure and fully unit-testable.
class SensorSnapshot {
  // ── Accelerometer ─────────────────────────────────────────────────────────

  /// EMA-smoothed accelerometer magnitude delta (g) for this epoch.
  final double motionMagnitude;

  /// Standard deviation of raw magnitude readings — low = stable position.
  final double motionVariance;

  /// Rolling 10-minute average of EMA-smoothed per-minute magnitudes.
  final double rollingAverageMotion;

  /// Linear regression slope of the rolling motion window.
  /// Negative = declining motion (sleep onset); positive = waking.
  final double motionTrendSlope;

  // ── Gyroscope ─────────────────────────────────────────────────────────────

  /// EMA-smoothed gyroscope angular velocity magnitude (rad/s).
  /// Low value → stable phone orientation.
  final double gyroMagnitude;

  /// Standard deviation of gyro readings in the burst window.
  final double gyroVariance;

  // ── Screen & Interaction ──────────────────────────────────────────────────

  /// True if the device screen is currently off at end of epoch.
  final bool isScreenOff;

  /// Seconds the screen was ON during this epoch (0–60).
  final int screenOnDurationSecs;

  /// Number of device unlock events detected during this epoch.
  final int unlockCount;

  /// Estimated touch/interaction events during this epoch.
  /// 0 if accessibility service unavailable (approximated from screen duration).
  final int touchEventCount;

  // ── Charging & Battery ────────────────────────────────────────────────────

  /// True if the device is currently charging.
  final bool isCharging;

  /// Battery level 0–100. -1 if unavailable.
  final int batteryLevel;

  // ── Ambient Environment ───────────────────────────────────────────────────

  /// Ambient light in lux. 0.0 if sensor unavailable.
  /// Context-only — never used as a sole sleep indicator.
  final double ambientLux;

  /// True if the proximity sensor reports something close (e.g., face-down).
  /// False if sensor unavailable or nothing detected.
  final bool proximityNear;

  // ── Computed Normalized Scores (0–100) ────────────────────────────────────

  /// Combined movement score from accelerometer + gyroscope.
  /// 0 = completely still, 100 = highly active.
  final int movementScore;

  /// Phone usage score from screen + unlock + touch signals.
  /// 0 = screen off, no interaction; 100 = actively using phone.
  final int activityScore;

  /// Environmental context score from ambient light + time of day.
  /// 0 = bright/daytime context; 100 = dark/nighttime context.
  final int environmentalScore;

  // ── Activity Recognition ──────────────────────────────────────────────────

  /// Android Activity Recognition. Values: 'still', 'walking', 'running', 'unknown'.
  final String? activityRecognition;

  /// Timestamp of this snapshot.
  final DateTime timestamp;

  const SensorSnapshot({
    required this.motionMagnitude,
    required this.motionVariance,
    this.rollingAverageMotion = 0.0,
    this.motionTrendSlope = 0.0,
    this.gyroMagnitude = 0.0,
    this.gyroVariance = 0.0,
    required this.isScreenOff,
    this.screenOnDurationSecs = 0,
    this.unlockCount = 0,
    this.touchEventCount = 0,
    required this.isCharging,
    this.batteryLevel = -1,
    this.ambientLux = 0.0,
    this.proximityNear = false,
    this.movementScore = -1,   // -1 = not yet computed
    this.activityScore = -1,
    this.environmentalScore = -1,
    this.activityRecognition,
    required this.timestamp,
  });

  // ── Computed score helpers ────────────────────────────────────────────────

  /// Movement score 0–100: combines accel + gyro.
  /// Returns cached value if pre-computed, otherwise computes on demand.
  int get effectiveMovementScore {
    if (movementScore >= 0) return movementScore;
    // Accelerometer contribution (0–70) + gyro contribution (0–30)
    const accelMax = 0.50; // g
    const accelMin = 0.04; // g
    final accelNorm = ((accelMax - motionMagnitude.clamp(accelMin, accelMax)) /
            (accelMax - accelMin) *
            70)
        .round()
        .clamp(0, 70);
    const gyroMax = 0.30; // rad/s
    const gyroMin = 0.01;
    final gyroNorm = ((gyroMax - gyroMagnitude.clamp(gyroMin, gyroMax)) /
            (gyroMax - gyroMin) *
            30)
        .round()
        .clamp(0, 30);
    // Higher score = MORE still (inverted from raw signal)
    return (accelNorm + gyroNorm).clamp(0, 100);
  }

  /// Activity score 0–100: screen + unlock + touch.
  int get effectiveActivityScore {
    if (activityScore >= 0) return activityScore;
    // Screen-on time contribution (0–50)
    final screenPts = (screenOnDurationSecs.clamp(0, 60) / 60.0 * 50).round();
    // Unlock contribution (0–30) — each unlock adds 15pts, max 2
    final unlockPts = (unlockCount.clamp(0, 2) * 15).clamp(0, 30);
    // Touch contribution (0–20)
    final touchPts = (touchEventCount.clamp(0, 4) * 5).clamp(0, 20);
    return (screenPts + unlockPts + touchPts).clamp(0, 100);
  }

  /// Environmental score 0–100: dark + nighttime = higher score.
  int get effectiveEnvironmentalScore {
    if (environmentalScore >= 0) return environmentalScore;
    // Ambient light (0–60): darkness score
    const luxDark = 5.0;
    const luxBright = 200.0;
    final luxScore = ambientLux <= luxDark
        ? 60
        : ambientLux >= luxBright
            ? 0
            : ((luxBright - ambientLux) / (luxBright - luxDark) * 60)
                .round()
                .clamp(0, 60);
    // Proximity face-down bonus (+10)
    final proxPts = proximityNear ? 10 : 0;
    // Time already handled in confidence scorer via night window
    return (luxScore + proxPts).clamp(0, 100);
  }
}

// ─── State Machine Output ────────────────────────────────────────────────────

class StateMachineResult {
  final SleepState newState;
  final int confidenceScore; // 0–100
  final String? debugReason; // For logging — not printed in production

  /// Estimated phone position for this epoch (null when state is Awake).
  final PhonePositionEstimate? phonePosition;

  /// Awakening type — only set when in PossibleWake state.
  final AwakeningType? awakeningType;

  /// The timestamp when [SleepState.possibleSleep] first began.
  /// Non-null only on the tick that transitions Awake → PossibleSleep.
  /// Used by [SleepDetectionService] to backdate the session start time
  /// to actual sleep onset rather than the confirmation time.
  final DateTime? possibleSleepStartTime;

  /// When the wake bout that ended the session began. Set on the tick that
  /// confirms PossibleWake → Awake, so the session ends when the user woke,
  /// not when the wake was confirmed.
  final DateTime? wakeOnsetTime;

  const StateMachineResult({
    required this.newState,
    required this.confidenceScore,
    this.debugReason,
    this.phonePosition,
    this.awakeningType,
    this.possibleSleepStartTime,
    this.wakeOnsetTime,
  });
}

// ─── State Machine ────────────────────────────────────────────────────────────

class SleepStateMachine {
  /// Mutable live config — updated each tick from SharedPreferences by
  /// [SleepDetectionService.updateConfig()]. Never use a stale constructor value.
  SleepDetectionConfig _liveConfig;

  /// Always returns the latest runtime config (night window hours, nap mode, etc.).
  SleepDetectionConfig get config => _liveConfig;

  /// Pushes a fresh config into the state machine. Called by the service layer
  /// before every [evaluate()] call so the window/nap settings stay in sync.
  void updateConfig(SleepDetectionConfig newConfig) {
    _liveConfig = newConfig;
  }

  SleepState _state = SleepState.awake;
  SleepState get currentState => _state;

  /// Counts consecutive minutes the machine has been in PossibleSleep.
  int _possibleSleepMinutes = 0;

  /// Counts consecutive minutes the machine has been in PossibleWake.
  int _possibleWakeMinutes = 0;

  /// Timestamp when [SleepState.possibleSleep] first began.
  /// Used to backdate the session start so it reflects when the user
  /// actually became still, not when sleeping was confirmed (25+ min later).
  DateTime? _possibleSleepStartTime;

  /// Timestamp when [SleepState.possibleWake] began.
  DateTime? _possibleWakeStartTime;

  /// Timestamp when the current session entered the Sleeping state.
  /// Used for the alarm-gap guard.
  DateTime? _sleepStartTime;

  /// Timestamp of the last screen-on event (provided externally).
  /// Used to apply the social activity gate.
  DateTime? _lastScreenOnTime;

  /// Restores internal state machine state upon service restoration from SharedPreferences.
  void restoreState({
    required SleepState state,
    DateTime? sleepStartTime,
    DateTime? possibleSleepStartTime,
    DateTime? morningWakeOnset,
  }) {
    _state = state;
    _sleepStartTime = sleepStartTime;
    _possibleSleepStartTime = possibleSleepStartTime;
    _possibleSleepMinutes = 0;
    _possibleWakeMinutes = 0;
    _possibleWakeStartTime = null;
    _wakeBoutScreenSecs = 0;
    _wakeBoutGotUp = false;
    _morningWakeOnset = morningWakeOnset;
    _settledMinutes = 0;
  }

  /// Stores recent motion magnitudes for gradient analysis (false-positive guard).
  /// The gradient is the slope of the motion decline over the last
  /// [_gradientWindowMinutes] samples. A sudden drop (e.g. "put phone down")
  /// looks different from a gradual one (genuine sleep onset).
  final List<double> _recentMagnitudes = [];

  /// Number of minutes of magnitude history to consider for gradient detection.
  /// 10 minutes is enough to distinguish step-drop (put down) from gradual decline.
  static const int _gradientWindowMinutes = 10;

  /// Core night hours: 10 PM – 5 AM. Used in time-of-day confidence scoring.
  /// Shoulder hours (nightWindowStart – 10 PM and 5 AM – nightWindowEnd) get
  /// reduced time-of-day points to reflect that sleep is less likely.
  /// Also separates a brief night awakening (inside) from getting up (outside).
  static const int _coreNightStartHour = 22; // 10 PM
  static const int _coreNightEndHour = 5;    // 5 AM

  static bool isCoreNight(DateTime dt) =>
      dt.hour >= _coreNightStartHour || dt.hour < _coreNightEndHour;

  /// Screen-on seconds accumulated during the current PossibleWake bout.
  int _wakeBoutScreenSecs = 0;

  /// Whether the current PossibleWake bout had a strong signal outside core
  /// night. Unplugging is a one-minute event, so it must outlast its tick.
  bool _wakeBoutGotUp = false;

  /// First wake signal outside core night since the user last lay still for
  /// [backToSleepMinutes]. Someone who gets up and leaves in a hurry gives a
  /// burst of motion, then nothing the tracker can confirm (phone on a table,
  /// in a bag, in a vehicle) until they use it somewhere else. That later use
  /// confirms the wake, but this is when they got up.
  DateTime? _morningWakeOnset;
  DateTime? get morningWakeOnset => _morningWakeOnset;

  /// Consecutive Sleeping minutes with the phone lying still.
  int _settledMinutes = 0;

  /// Lying still this long after a morning wake signal means the user went
  /// back to sleep, so that signal no longer marks when they got up.
  static const int backToSleepMinutes = 30;

  /// Whether the phone was on the charger at the previous tick.
  bool _wasCharging = false;

  SleepStateMachine({SleepDetectionConfig config = const SleepDetectionConfig()})
      : _liveConfig = config;

  /// Notify the state machine of a screen-on event so it can update
  /// the social activity gate timestamp.
  void onScreenOn(DateTime timestamp) {
    _lastScreenOnTime = timestamp;
  }

  /// Primary entry point. Call once per minute with the latest sensor snapshot.
  /// [circadianWeight] is an optional multiplier (0.5–1.5) from [SleepPatternLearner]
  /// that amplifies or dampens detection sensitivity based on the user's typical bedtime.
  /// [confidenceCeiling] caps the score to what the device's actual sensor set can
  /// support (from [SensorCapabilityManager]) — e.g. a phone missing a gyroscope
  /// or ambient light sensor shouldn't be able to reach the same peak confidence
  /// as one with full sensor coverage.
  StateMachineResult evaluate(
    SensorSnapshot snapshot, {
    double circadianWeight = 1.0,
    int confidenceCeiling = 100,
  }) {
    final score = _computeConfidenceScore(
      snapshot,
      circadianWeight: circadianWeight,
      confidenceCeiling: confidenceCeiling,
    );
    final inNightWindow = _isInNightWindow(snapshot.timestamp);
    final position = PhonePositionEstimator.estimate(snapshot);
    final unplugged = _wasCharging && !snapshot.isCharging;
    _wasCharging = snapshot.isCharging;

    // Update magnitude history for gradient analysis.
    _recentMagnitudes.add(snapshot.motionMagnitude);
    if (_recentMagnitudes.length > _gradientWindowMinutes) {
      _recentMagnitudes.removeAt(0);
    }

    // ── Main state transition logic ───────────────────────────────────────

    switch (_state) {
      case SleepState.awake:
        // ── Active-use gate ───────────────────────────────────────────────
        // Do NOT enter PossibleSleep if the screen was on for > 30s this
        // minute — the user is actively using the phone (scrolling, reading,
        // watching). touchEventCount is intentionally not checked here because
        // the accessibility service is unavailable on most devices.
        // Counted over the whole minute: the screen may already be off at
        // the moment of the tick even though it was in use.
        final isActivelyUsingPhone = snapshot.screenOnDurationSecs > 30;
        if (inNightWindow &&
            score >= config.sleepConfirmThreshold &&
            !isActivelyUsingPhone) {
          _state = SleepState.possibleSleep;
          _possibleSleepMinutes = 1;
          // Record the moment PossibleSleep began so the service can
          // backdate the session start to actual sleep onset.
          _possibleSleepStartTime = snapshot.timestamp;
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            phonePosition: position,
            possibleSleepStartTime: _possibleSleepStartTime,
            debugReason: 'Awake→PossibleSleep: score=$score pos=${position.name}',
          );
        }
        return StateMachineResult(
          newState: _state,
          confidenceScore: score,
          debugReason: 'Awake: score=$score inNight=$inNightWindow activeUse=$isActivelyUsingPhone',
        );

      case SleepState.possibleSleep:
        // ── Reading-in-bed guard ───────────────────────────────────────────
        // Screen on > 20s is sufficient evidence of active use (reading,
        // scrolling, watching). We intentionally do NOT require touchEventCount > 0
        // because the accessibility service is unavailable on most devices,
        // meaning touchEventCount is always 0 and the original guard was dead code.
        if (snapshot.screenOnDurationSecs > 20) {
          _possibleSleepMinutes = 0;
          // Restart the onset clock too. The wall-clock count below measures
          // from _possibleSleepStartTime, so keeping the old start would undo
          // this reset on the next tick, and the session would be backdated
          // to before the phone use.
          _possibleSleepStartTime = snapshot.timestamp.add(const Duration(minutes: 1));
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            phonePosition: position,
            debugReason: 'PossibleSleep: reading-in-bed guard reset (screen=${snapshot.screenOnDurationSecs}s)',
          );
        }

        if (!inNightWindow || score < config.sleepDismissThreshold) {
          // Conditions broken — reset back to Awake.
          _possibleSleepMinutes = 0;
          _possibleSleepStartTime = null; // clear onset timestamp on dismissal
          _state = SleepState.awake;
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            debugReason: 'PossibleSleep→Awake: score=$score dismissed',
          );
        }

        if (score >= config.sleepConfirmThreshold) {
          if (_possibleSleepStartTime != null) {
            final elapsedWallClockMins =
                snapshot.timestamp.difference(_possibleSleepStartTime!).inMinutes + 1;
            _possibleSleepMinutes = math.max(_possibleSleepMinutes + 1, elapsedWallClockMins);
          } else {
            _possibleSleepMinutes++;
          }
        } else {
          // Score dropped into hysteresis band (50–64) — hold, don't reset.
          // The person may be briefly shifting position.
        }

        // ── TV-watching / false positive guard ────────────────────────────
        // Scenario: nighttime, screen off, charging, low motion — but the person
        // is just watching TV (phone on the couch). We require phone to be in a
        // confirmed sleep position (onMattress / nearPillow) OR have been in
        // PossibleSleep for longer before confirming (35 min instead of 25).
        final tvGuardActive = position == PhonePositionEstimate.likelyHandheld ||
            position == PhonePositionEstimate.unknown;
        final effectiveOnsetMinutes = tvGuardActive
            ? math.max(_effectiveSleepOnsetMinutes(snapshot.timestamp), 35)
            : _effectiveSleepOnsetMinutes(snapshot.timestamp);

        // Check motion gradient: abrupt step-drop suggests "just put phone down".
        final isGradualDecline = _isGradualMotionDecline();

        if (_possibleSleepMinutes >= effectiveOnsetMinutes && isGradualDecline) {
          _state = SleepState.sleeping;
          _sleepStartTime = snapshot.timestamp;
          _morningWakeOnset = null;
          _settledMinutes = 0;
          final onsetTime = _possibleSleepStartTime; // capture before clearing
          _possibleSleepStartTime = null;
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            phonePosition: position,
            possibleSleepStartTime: onsetTime, // service uses this to backdate start
            debugReason:
                'PossibleSleep→Sleeping after ${_possibleSleepMinutes}min, gradual=$isGradualDecline tvGuard=$tvGuardActive pos=${position.name}',
          );
        }

        return StateMachineResult(
          newState: _state,
          confidenceScore: score,
          phonePosition: position,
          debugReason:
              'PossibleSleep: min=$_possibleSleepMinutes/$effectiveOnsetMinutes score=$score tvGuard=$tvGuardActive pos=${position.name}',
        );

      case SleepState.sleeping:
        final signals = _wakeSignals(snapshot, unplugged: unplugged);
        if (signals.any) {
          _state = SleepState.possibleWake;
          _possibleWakeStartTime = snapshot.timestamp;
          _possibleWakeMinutes = 1;
          _wakeBoutScreenSecs = snapshot.screenOnDurationSecs;
          _wakeBoutGotUp = signals.strong && !isCoreNight(snapshot.timestamp);
          _settledMinutes = 0;
          if (!isCoreNight(snapshot.timestamp)) _morningWakeOnset ??= snapshot.timestamp;
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            phonePosition: position,
            awakeningType: AwakeningType.glance, // initial label — updated each tick
            debugReason: 'Sleeping→PossibleWake: ${signals.reason}',
          );
        }

        // A moving phone with no wake signal (a vehicle, a bag) is not
        // someone back in bed, so only still minutes count.
        if (snapshot.motionMagnitude < config.effectiveLowMotionThreshold) {
          _settledMinutes++;
          if (_settledMinutes >= backToSleepMinutes) _morningWakeOnset = null;
        } else {
          _settledMinutes = 0;
        }

        return StateMachineResult(
          newState: _state,
          confidenceScore: score,
          phonePosition: position,
          debugReason: 'Sleeping: score=$score pos=${position.name}',
        );

      case SleepState.possibleWake:
        final signals = _wakeSignals(snapshot, unplugged: unplugged);
        _wakeBoutScreenSecs += snapshot.screenOnDurationSecs;
        final coreNight = isCoreNight(snapshot.timestamp);
        if (signals.any && !coreNight) _morningWakeOnset ??= snapshot.timestamp;
        if (signals.strong && !coreNight) _wakeBoutGotUp = true;

        // ── Awakening type label (updated each tick in PossibleWake) ──────
        final AwakeningType awakeType;
        final hasInteraction = snapshot.unlockCount > 0 || snapshot.touchEventCount > 0;
        if (_possibleWakeMinutes < 2 && !hasInteraction) {
          awakeType = AwakeningType.glance;
        } else if (_possibleWakeMinutes < 5) {
          awakeType = AwakeningType.briefAwakening;
        } else {
          awakeType = AwakeningType.fullWake;
        }

        // Getting up: outside core night, an unlock, walking, unplugging the
        // charger or a minute of screen use means the night is over. Inside
        // core night the same signals are a brief awakening unless they last
        // (see below).
        final gotUp = !coreNight &&
            (_wakeBoutGotUp || _wakeBoutScreenSecs >= gotUpScreenSecs);
        if (gotUp || signals.napCap) {
          return _confirmWake(
            snapshot, score,
            reason: 'PossibleWake→Awake: ${gotUp ? 'got up' : 'nap cap'} (${signals.reason}, screen=${_wakeBoutScreenSecs}s)',
          );
        }

        if (!signals.any) {
          // Conditions cleared. But check if the motion trend is still rising:
          if (snapshot.motionTrendSlope > 0.005 && _possibleWakeMinutes < 2) {
            // Trend still rising: hold position, don't snap back yet.
            _possibleWakeMinutes++;
            return StateMachineResult(
              newState: _state,
              confidenceScore: score,
              phonePosition: position,
              awakeningType: awakeType,
              debugReason:
                  'PossibleWake: holding — rising trend slope=${snapshot.motionTrendSlope.toStringAsFixed(4)}',
            );
          }
          // Trend flat or declining: a brief awakening, back to Sleeping.
          _possibleWakeMinutes = 0;
          _possibleWakeStartTime = null;
          _wakeBoutScreenSecs = 0;
          _wakeBoutGotUp = false;
          _state = SleepState.sleeping;
          return StateMachineResult(
            newState: _state,
            confidenceScore: score,
            phonePosition: position,
            awakeningType: awakeType,
            debugReason: 'PossibleWake→Sleeping: conditions cleared (${awakeType.name})',
          );
        }

        // Wall-clock minutes since the wake bout began (ticks can be late)
        final elapsedWakeMins =
            snapshot.timestamp.difference(_possibleWakeStartTime!).inMinutes + 1;
        _possibleWakeMinutes = math.max(_possibleWakeMinutes + 1, elapsedWakeMins);

        // Sharply rising motion: the user is clearly moving about.
        if (snapshot.motionTrendSlope > 0.05) {
          _possibleWakeMinutes = math.max(_possibleWakeMinutes, config.wakeConfirmMinutes);
        }

        if (_possibleWakeMinutes >= config.wakeConfirmMinutes) {
          return _confirmWake(
            snapshot, score,
            reason: 'PossibleWake→Awake: signals lasted ${config.wakeConfirmMinutes}min (${signals.reason})',
          );
        }

        return StateMachineResult(
          newState: _state,
          confidenceScore: score,
          phonePosition: position,
          awakeningType: awakeType,
          debugReason:
              'PossibleWake: min=$_possibleWakeMinutes/${config.wakeConfirmMinutes} type=${awakeType.name}',
        );
    }
  }

  /// Screen use in one wake bout (outside core night) that means the user is up.
  static const int gotUpScreenSecs = 60;

  /// Screen time in one minute that counts as using the phone, not glancing.
  static const int sustainedUseSecs = 30;

  /// This minute's evidence that the user may be awake.
  /// `strong` signals come from the user, not just the phone moving:
  /// unlocking it, walking (from activity recognition) or taking it off the
  /// charger. Screen, unlock and unplug are ignored during the alarm gap
  /// right after sleep onset, when a last glance at the phone is common.
  ({bool any, bool strong, bool napCap, String reason}) _wakeSignals(
    SensorSnapshot s, {
    required bool unplugged,
  }) {
    final minsAsleep = _sleepStartTime == null ? 0 : s.timestamp.difference(_sleepStartTime!).inMinutes;
    final pastAlarmGap = minsAsleep > config.alarmGapMinutes;

    final motion = s.motionMagnitude > config.effectiveHighMotionThreshold;
    // The alarm gap forgives a glance, not real use: half a minute or more of
    // screen time means the user is awake, however soon after onset.
    final sustainedUse = s.screenOnDurationSecs >= sustainedUseSecs;
    final screen = sustainedUse || (pastAlarmGap && (!s.isScreenOff || s.screenOnDurationSecs > 0));
    final unlock = pastAlarmGap && s.unlockCount > 0;
    final walking = s.activityRecognition?.toLowerCase() == 'walking';
    final unplug = pastAlarmGap && unplugged;
    final napCap = config.isNapMode && minsAsleep >= 180;

    return (
      any: motion || screen || unlock || walking || unplug || napCap,
      strong: unlock || walking || unplug,
      napCap: napCap,
      reason: 'motion=$motion screen=$screen unlock=$unlock walking=$walking unplug=$unplug',
    );
  }

  /// Ends the session: the result carries when the user woke — the morning
  /// wake onset when there is one, else when this wake bout began.
  StateMachineResult _confirmWake(SensorSnapshot snapshot, int score, {required String reason}) {
    final boutStart = _possibleWakeStartTime!;
    final morning = _morningWakeOnset;
    final wakeOnset = morning != null && morning.isBefore(boutStart) ? morning : boutStart;
    _state = SleepState.awake;
    _possibleWakeMinutes = 0;
    _possibleWakeStartTime = null;
    _wakeBoutScreenSecs = 0;
    _wakeBoutGotUp = false;
    _possibleSleepMinutes = 0;
    _sleepStartTime = null;
    _morningWakeOnset = null;
    _settledMinutes = 0;
    _recentMagnitudes.clear();
    return StateMachineResult(
      newState: _state,
      confidenceScore: score,
      awakeningType: AwakeningType.fullWake,
      wakeOnsetTime: wakeOnset,
      debugReason: reason,
    );
  }

  // ─── Confidence Scoring (full 9-signal weighted formula + Phase 3 additions) ─

  int _computeConfidenceScore(
    SensorSnapshot snap, {
    double circadianWeight = 1.0,
    int confidenceCeiling = 100,
  }) {
    int score = 0;

    // ── 0. Phone position bonus/penalty ───────────────────────────────────
    // Applied first so later signals are modulated on a position-aware base.
    final position = PhonePositionEstimator.estimate(snap);
    score += PhonePositionEstimator.confidenceDelta(position);

    // ── 1. Time-of-day / night window (0–20 pts) ──────────────────────────
    // Full 20pts during core night window. Proportional within outer window.
    // Phase 3: circadianWeight amplifies/dampens the night-window contribution.
    if (_isInNightWindow(snap.timestamp)) {
      // Core night (10 PM – 5 AM) earns full points; shoulder hours get partial.
      final rawTimePts = isCoreNight(snap.timestamp) ? 20 : 12;
      // Apply circadian weight: multiply and round. Cap 0–28 (allows boost up to +40%).
      score += (rawTimePts * circadianWeight).round().clamp(0, 28);
    }

    // ── 2. Movement score (0–25 pts) ─────────────────────────────────────
    // movementScore 0–100: 100 = perfectly still, 0 = highly active.
    // We use the pre-computed effectiveMovementScore (accel + gyro).
    // Charging bias: a charging phone sitting still gets +20% magnitude
    // deflation, so require higher stillness confidence to compensate.
    final mScore = snap.effectiveMovementScore;
    final chargingPenalty = snap.isCharging ? 5 : 0;
    final movementPts = ((mScore / 100.0) * 25).round() - chargingPenalty;
    score += movementPts.clamp(0, 25);

    // ── 3. Screen off (0–15 pts) ──────────────────────────────────────────
    if (snap.isScreenOff) {
      score += 15;
    } else {
      // Partial credit: if screen was on briefly (< 10s) may be notification glance.
      if (snap.screenOnDurationSecs < 10) score += 7;
    }

    // ── 4. No user interaction (0–15 pts) ────────────────────────────────
    // activityScore 0–100: 0 = no interaction. Invert: no activity → points.
    final aScore = snap.effectiveActivityScore;
    final interactionPts = (((100 - aScore) / 100.0) * 15).round();
    score += interactionPts.clamp(0, 15);

    // ── 5. Charging (0–10 pts, time-aware) ───────────────────────────────
    if (snap.isCharging) {
      // Charging is only meaningful during the configured night window (or any
      // time when nap mode is on). Uses user-configured hours, not hardcoded values.
      final inWindow = _isInNightWindow(snap.timestamp);
      score += inWindow ? 10 : 2; // daytime charging = very weak signal
    }

    // ── 6. Ambient light / environmental (0–10 pts) ───────────────────────
    // environmentalScore 0–100: 100 = very dark/still. Scale to 10 pts.
    final envPts = ((snap.effectiveEnvironmentalScore / 100.0) * 10).round();
    score += envPts.clamp(0, 10);

    // ── 7. Stable orientation / gyroscope (0–5 pts) ───────────────────────
    // Very low gyro variance = phone hasn't been rotated or picked up.
    if (snap.gyroVariance < 0.02) {
      score += 5;
    } else if (snap.gyroVariance < 0.08) {
      score += 2;
    }

    // ── 8. Activity Recognition (0–5 pts) ────────────────────────────────
    // This is now a smaller contributor since movement score already covers it.
    switch (snap.activityRecognition?.toLowerCase()) {
      case 'still':
        score += 5;
        break;
      case 'unknown':
        score += 2;
        break;
      default:
        break;
    }

    // ── 9. Motion trend direction (0 or +/−5 pts) ────────────────────────
    // Declining motion trend supports sleep onset; rising supports wake.
    if (snap.motionTrendSlope < -0.01) {
      score += 5; // sustained decline → genuine sleep onset pattern
    } else if (snap.motionTrendSlope > 0.02) {
      score -= 5; // rising motion → waking up
    }

    return score.clamp(0, confidenceCeiling.clamp(0, 100));
  }

  // ─── Helper Methods ───────────────────────────────────────────────────────

  bool _isInNightWindow(DateTime dt) {
    if (config.isNapMode) return true; // Nap mode overrides daytime window restriction
    final h = dt.hour;
    return h >= config.nightWindowStartHour || h < config.nightWindowEndHour;
  }

  int _effectiveSleepOnsetMinutes(DateTime now) {
    final baseOnset = config.effectiveOnsetMinutesBase;
    if (_lastScreenOnTime == null) return baseOnset;

    final minutesSinceUse = now.difference(_lastScreenOnTime!).inMinutes;
    if (minutesSinceUse < config.recentUsageWindowMinutes) {
      return baseOnset + config.recentUsagePenaltyMinutes;
    }
    return baseOnset;
  }

  /// Returns true if the recent motion magnitude history shows a GRADUAL
  /// decline rather than an abrupt step-drop.
  ///
  /// A sudden step-drop (reading in bed, then putting phone down) shows a
  /// change ratio > 0.6 in the last 2 samples relative to the window mean.
  /// Genuine sleep onset shows a smoother decline.
  ///
  /// If we have fewer than 3 data points, we cannot determine the gradient
  /// and return true (give benefit of the doubt — onset timer is the guard).
  bool _isGradualMotionDecline() {
    if (_recentMagnitudes.length < 3) return true;

    final n = _recentMagnitudes.length;
    // Compute simple linear regression slope over the window.
    // A negative slope means motion is declining (expected for sleep onset).
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < n; i++) {
      sumX += i;
      sumY += _recentMagnitudes[i];
      sumXY += i * _recentMagnitudes[i];
      sumX2 += i * i.toDouble();
    }
    final denom = n * sumX2 - sumX * sumX;
    if (denom == 0) return true;
    final slope = (n * sumXY - sumX * sumY) / denom;

    // Also check the last-2-sample ratio as a step-drop guard.
    final lastTwo = _recentMagnitudes.sublist(math.max(0, n - 2));
    final prev = lastTwo.first;
    final curr = lastTwo.last;
    final stepRatio = prev > 0 ? (prev - curr).abs() / prev : 0.0;

    // A step-drop: last 2 samples changed by > 60% of the previous value.
    // A negative slope: motion is actually declining (not just noisy).
    if (stepRatio > 0.6 && slope < -0.02) {
      // Abrupt drop — likely put-phone-down, not sleep onset.
      return false;
    }
    return true;
  }

  // ─── Test Helpers ─────────────────────────────────────────────────────────

  /// Forcibly set state — for unit testing only. Do not call from production code.
  // ignore: avoid_setters_without_getters
  set stateForTesting(SleepState s) => _state = s;

  void setPossibleSleepMinutesForTesting(int m) => _possibleSleepMinutes = m;
  void setPossibleWakeMinutesForTesting(int m) => _possibleWakeMinutes = m;
  void setSleepStartTimeForTesting(DateTime t) => _sleepStartTime = t;
}
