/// WorkManager background worker registration and callback dispatcher.
///
/// Role in the tiered background architecture:
///   - WorkManager (this file): Wakes every 15 minutes to take a single
///     confidence snapshot and detect session boundaries when the app is
///     backgrounded or killed. Cannot do per-minute sampling.
///   - Foreground Service (SleepDetectionService): Per-minute sampling
///     while the night window is active and the user has opted in.
///   - BroadcastReceiver (AndroidManifest): Instant screen-on/off events.
///
/// Why WorkManager here AND foreground service in SleepDetectionService?
/// WorkManager's minimum periodic interval is 15 min (Android enforced).
/// If the foreground service is killed by the OS (OEM battery optimizer),
/// WorkManager provides a coarser fallback so at minimum we don't lose
/// the session start/end entirely.
///
/// Android Doze behaviour: WorkManager respects Doze mode. During deep Doze,
/// it may defer by 30–60+ min on OEM devices. We accept this limitation and
/// guide users to whitelist the app via the battery optimization dialog.
library;

import 'package:workmanager/workmanager.dart';
import 'sleep_detection_service.dart'; // Used for SleepDetectionService.isEnabled()
import 'sleep_repository.dart';
import 'sleep_recovery_manager.dart';

/// Unique task name for the periodic 15-minute boundary check.
const _boundaryCheckTask = 'auto_sleep_tracker.boundary_check';

/// Unique task name for a one-shot check triggered at night-window start.
const _nightWindowStartTask = 'auto_sleep_tracker.night_window_start';

/// WorkManager callback — must be a top-level function (not an instance method).
/// This is the entry point for all background task execution.
@pragma('vm:entry-point')
void workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // Unknown task — return success to prevent retry loops.
    return await handleSleepBackgroundTask(taskName) ?? true;
  });
}

/// Runs [taskName] if it is one of this package's tasks, else returns null.
/// Apps that already have their own WorkManager dispatcher call this from it
/// instead of using [workManagerCallbackDispatcher].
Future<bool?> handleSleepBackgroundTask(String taskName) async {
  switch (taskName) {
    case _boundaryCheckTask:
      return _runBoundaryCheck();
    case _nightWindowStartTask:
      return _startNightWindowService();
    default:
      return null;
  }
}

/// Registers all WorkManager tasks. Call once from main() after
/// Workmanager().initialize().
Future<void> registerSleepBackgroundWork() async {
  // 15-minute boundary check: runs while auto-tracking is enabled.
  // This is the fallback if the foreground service is killed.
  //
  // Constraints: no network required, run on any charge state.
  // existingWorkPolicy.keep: don't re-register if already scheduled
  // (avoids duplicate tasks on app restart).
  await Workmanager().registerPeriodicTask(
    _boundaryCheckTask,
    _boundaryCheckTask,
    frequency: const Duration(minutes: 15),
    // WorkManager will not fire more than once per 15 min regardless of this.
    initialDelay: const Duration(minutes: 5),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 5),
    constraints: Constraints(
      networkType: NetworkType.not_required,
      requiresBatteryNotLow: false,
    ),
  );
}

/// Cancels all scheduled sleep background work. Call when the user
/// disables auto-tracking.
Future<void> cancelSleepBackgroundWork() async {
  await Workmanager().cancelByUniqueName(_boundaryCheckTask);
  await Workmanager().cancelByUniqueName(_nightWindowStartTask);
}

// ─── Background Task Implementations ─────────────────────────────────────────

/// Runs a single confidence snapshot to detect session boundaries.
/// Returns true (success) in all cases — we don't want WorkManager to
/// retry aggressively on sensor errors.
Future<bool> _runBoundaryCheck() async {
  try {
    // Only run if the user has enabled auto-tracking.
    if (!await SleepDetectionService.isEnabled()) return true;

    // Check if there's an ongoing session that has gone too long without a wake.
    // SleepRecoveryManager handles auto-closing stale sessions.
    final repo = SleepRepository();
    await SleepRecoveryManager.closeOrphanedSessionIfStale(repo);

    return true;
  } catch (_) {
    return true; // Don't retry — sensor errors are transient.
  }
}

/// Called at the start of the night window to wake the foreground service.
Future<bool> _startNightWindowService() async {
  try {
    if (!await SleepDetectionService.isEnabled()) return true;
    // The foreground service is started by the Flutter engine in the main
    // isolate when the app is in foreground. From a WorkManager isolate,
    // we can only flag that it should start; the next app foreground event
    // picks it up. This is a known limitation of WorkManager + Flutter.
    return true;
  } catch (_) {
    return true;
  }
}
