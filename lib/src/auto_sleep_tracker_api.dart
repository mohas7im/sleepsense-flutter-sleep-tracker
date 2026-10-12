import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:workmanager/workmanager.dart';

import 'os_capability_manager.dart';
import 'sensor_capability_manager.dart';
import 'sleep_background_service.dart';
import 'sleep_background_worker.dart';
import 'sleep_detection_service.dart';
import 'sleep_recovery_manager.dart';
import 'sleep_repository.dart';

/// One-stop entry point for automatic sleep tracking.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await AutoSleepTracker.initialize();
///   runApp(const MyApp());
/// }
///
/// // Once the user opts in (after granting permissions):
/// await AutoSleepTracker.enable();
///
/// // Read the history:
/// final nights = await AutoSleepTracker.repository.getRecentSessions(days: 7);
/// ```
class AutoSleepTracker {
  AutoSleepTracker._();

  static SleepRepository? _repository;

  /// Shared repository for reading sessions, epochs and stats.
  static SleepRepository get repository => _repository ??= SleepRepository();

  /// Configures background execution. Call once in `main()`, before
  /// `runApp()`.
  ///
  /// - [notificationTitle] / [notificationContent]: the foreground-service
  ///   notification Android shows while tracking runs.
  /// - [manualSessions]: sleep the user logged by hand in your app, merged
  ///   into [repository] queries.
  /// - [onSleepFinishedInBackground]: runs in the background isolate when a
  ///   night ends, even with your app closed — e.g. to show a morning
  ///   summary notification. Must be a top-level or static function
  ///   annotated `@pragma('vm:entry-point')`.
  /// - [initializeWorkManager]: set to false if your app already calls
  ///   `Workmanager().initialize` with its own dispatcher; then call
  ///   [handleSleepBackgroundTask] from that dispatcher.
  static Future<void> initialize({
    String notificationTitle = 'Sleep tracking',
    String notificationContent = 'Monitoring rest and sleep quality…',
    ManualSleepSource? manualSessions,
    void Function(SleepFinishedEvent event)? onSleepFinishedInBackground,
    bool initializeWorkManager = true,
  }) async {
    SleepRepository.defaultManualSessions = manualSessions;
    await saveSleepFinishedBackgroundCallback(onSleepFinishedInBackground);
    if (initializeWorkManager) {
      await Workmanager().initialize(workManagerCallbackDispatcher);
    }
    await initializeSleepBackgroundService(
      notificationTitle: notificationTitle,
      notificationContent: notificationContent,
    );
  }

  /// Whether the user has turned automatic tracking on (persisted).
  static Future<bool> isEnabled() => SleepDetectionService.isEnabled();

  /// Turns automatic tracking on: starts the overnight background service
  /// and the 15-minute WorkManager fallback. Request permissions first
  /// (see [requestPermissions]).
  static Future<void> enable() async {
    await SleepDetectionService.setEnabled(true);
    await startSleepBackgroundService();
    await registerSleepBackgroundWork();
  }

  /// Turns automatic tracking off and stops all background work.
  static Future<void> disable() async {
    await SleepDetectionService.setEnabled(false);
    await stopSleepBackgroundService();
    await cancelSleepBackgroundWork();
  }

  /// Call once when your app starts (e.g. from your first screen's
  /// `initState`). Repairs sessions left open by a killed process and
  /// restarts tracking if it was enabled.
  static Future<RecoveryResult> onAppStart() async {
    await repository.init();
    await SensorCapabilityManager.initialize();
    final result = await SleepRecoveryManager.recoverOnStartup(repository);
    if (await isEnabled()) {
      await startSleepBackgroundService();
      await registerSleepBackgroundWork();
    }
    return result;
  }

  /// Call when your app returns to the foreground. Ends a session the user
  /// has clearly woken up from and fixes wake times recorded late. Returns
  /// true when stored sessions changed, so you know to reload them.
  static Future<bool> onAppResumed() async {
    final closed = await SleepRecoveryManager.closeSessionIfAwake(repository);
    final corrected = await SleepRecoveryManager.correctRecentWakeTimes(repository);
    return closed || corrected;
  }

  /// Nights that just ended, delivered while your app's UI is running. To
  /// react with the app closed (e.g. a morning notification), pass
  /// `onSleepFinishedInBackground` to [initialize].
  static Stream<SleepFinishedEvent> get onSleepFinished => FlutterBackgroundService()
      .on(sleepFinishedServiceEvent)
      .where((data) => data != null)
      .map((data) => SleepFinishedEvent.fromMap(data!));

  /// Permissions and OS settings that affect tracking reliability.
  static Future<OSCapabilityReport> checkCapabilities() => OSCapabilityManager.check();

  /// Requests the notification and activity-recognition permissions.
  static Future<OSCapabilityReport> requestPermissions() =>
      OSCapabilityManager.requestMissingPermissions();
}
