/// Headless background execution host for [SleepDetectionService].
///
/// Why this file exists: the real per-minute sleep detection loop (Timer,
/// accelerometer/gyroscope streams, confidence scoring, SQLite writes) must
/// run somewhere that survives the user swiping the app out of Recent Apps —
/// the single most common thing people do right before going to sleep. A
/// plain `FlutterActivity` engine (the one behind the app's UI) does NOT
/// survive that; Android destroys it along with every Dart isolate, Timer,
/// and stream subscription tied to it.
///
/// `flutter_background_service` solves this by running its own dedicated
/// Android foreground service with `stopWithTask="false"`, hosting a
/// separate headless Flutter engine/isolate that keeps running independent
/// of the UI Activity's lifecycle. This file wires [SleepDetectionService]
/// into that headless isolate so it actually executes overnight instead of
/// dying the moment the Activity does.
library;

import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sleep_detection_service.dart';
import 'sleep_detection_logger.dart';

/// Service event carrying a [SleepFinishedEvent] map to the UI isolate.
const sleepFinishedServiceEvent = 'sleepFinished';

const _backgroundCallbackKey = 'sleep_finished_background_callback';

/// Remembers [callback] for the background isolate. Functions can't be
/// passed between isolates, so it is stored as a callback handle — which is
/// why it must be a top-level or static function marked
/// `@pragma('vm:entry-point')`.
Future<void> saveSleepFinishedBackgroundCallback(
  void Function(SleepFinishedEvent event)? callback,
) async {
  final prefs = await SharedPreferences.getInstance();
  final handle = callback == null ? null : PluginUtilities.getCallbackHandle(callback);
  if (handle == null) {
    await prefs.remove(_backgroundCallbackKey);
  } else {
    await prefs.setInt(_backgroundCallbackKey, handle.toRawHandle());
  }
}

Future<void Function(SleepFinishedEvent)?> _loadBackgroundCallback() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getInt(_backgroundCallbackKey);
  if (raw == null) return null;
  final callback = PluginUtilities.getCallbackFromHandle(CallbackHandle.fromRawHandle(raw));
  return callback is void Function(SleepFinishedEvent) ? callback : null;
}

/// Registers the background service configuration. Call once from `main()`,
/// before `runApp()`.
Future<void> initializeSleepBackgroundService({
  String notificationTitle = 'Sleep tracking',
  String notificationContent = 'Monitoring rest and sleep quality…',
}) async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onSleepServiceStart,
      // Only ever started explicitly via [startSleepBackgroundService] when
      // the user has auto-tracking enabled — never on every app boot.
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      initialNotificationTitle: notificationTitle,
      initialNotificationContent: notificationContent,
      foregroundServiceTypes: [AndroidForegroundType.health],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      // iOS does not support the same always-on background execution model
      // (BGTaskScheduler wakes are short, OS-scheduled, and infrequent), so
      // automatic per-minute overnight tracking is Android-only for now.
      onForeground: onSleepServiceStart,
      onBackground: _onIosBackgroundFetch,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> _onIosBackgroundFetch(ServiceInstance service) async {
  return true;
}

/// Entry point executed inside the headless background isolate. Must stay
/// a top-level function annotated `@pragma('vm:entry-point')` — the engine
/// looks it up by name via a callback handle, not a normal Dart reference.
@pragma('vm:entry-point')
void onSleepServiceStart(ServiceInstance service) async {
  // Registers every plugin declared in pubspec.yaml (sqflite,
  // shared_preferences, sensors_plus, battery_plus, pedometer,
  // permission_handler, ...) into this isolate's engine. Without this,
  // every plugin call below throws MissingPluginException.
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
  }

  // Relay finished nights to the UI isolate, if one is listening, and to
  // the app's background callback, which runs even with the app closed.
  final backgroundCallback = await _loadBackgroundCallback();
  SleepDetectionService.onSleepFinished = (event) {
    service.invoke(sleepFinishedServiceEvent, event.toMap());
    backgroundCallback?.call(event);
  };

  final detectionService = SleepDetectionService();

  service.on('stopService').listen((_) async {
    await detectionService.stop();
    service.stopSelf();
  });

  await SleepDetectionLogger().init();
  SleepDetectionLogger().logEvent(
    '🛰️ Headless background isolate started',
    level: 'INFO',
  );
  // This call's internal Timer.periodic is what keeps this isolate alive —
  // there is no separate "keep alive" loop needed here.
  await detectionService.start();
}

/// Starts the headless background service if it isn't already running.
/// Call this instead of [SleepDetectionService.start] directly — a
/// direct call would run the detection loop on the UI isolate, which dies
/// as soon as the Activity does (see this file's top-level doc comment).
Future<void> startSleepBackgroundService() async {
  final service = FlutterBackgroundService();
  final running = await service.isRunning();
  if (!running) {
    await service.startService();
  }
}

/// Stops the headless background service and its detection loop.
Future<void> stopSleepBackgroundService() async {
  final service = FlutterBackgroundService();
  final running = await service.isRunning();
  if (running) {
    service.invoke('stopService');
  }
}
