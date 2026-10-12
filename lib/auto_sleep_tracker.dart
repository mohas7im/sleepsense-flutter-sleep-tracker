/// Automatic, sensor-based sleep tracking for Flutter on Android.
///
/// Start with [AutoSleepTracker]; the lower-level building blocks
/// ([SleepStateMachine], [SleepRepository], [SleepRecoveryManager], …) are
/// exported for apps that want finer control.
library;

export 'src/auto_sleep_tracker_api.dart';
export 'src/health_connect_sleep_sync.dart';
export 'src/os_capability_manager.dart';
export 'src/sensor_capability_manager.dart';
export 'src/sleep_analysis_engine.dart';
export 'src/sleep_background_service.dart'
    show initializeSleepBackgroundService, startSleepBackgroundService, stopSleepBackgroundService;
export 'src/sleep_background_worker.dart';
export 'src/sleep_database.dart';
export 'src/sleep_detection_logger.dart';
export 'src/sleep_detection_service.dart';
export 'src/sleep_epoch.dart';
export 'src/sleep_pattern_profile.dart';
export 'src/sleep_quality_model.dart';
export 'src/sleep_recovery_manager.dart';
export 'src/sleep_repository.dart';
export 'src/sleep_session.dart';
export 'src/sleep_signals.dart';
export 'src/sleep_state_machine.dart';
