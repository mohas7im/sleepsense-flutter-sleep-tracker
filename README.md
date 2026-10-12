# auto_sleep_tracker

[![CI](https://github.com/mohas7im/auto_sleep_tracker/actions/workflows/ci.yml/badge.svg)](https://github.com/mohas7im/auto_sleep_tracker/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Automatic sleep tracking for Flutter on Android, with no wearable and no button to press.

The phone works out when you fell asleep and when you got up from signals it already has: motion, screen on/off, unlocks, ambient light, proximity, charging state and step activity. A foreground service runs the detection loop all night, even after the app is swiped away.

> ⚠️ **Wellness estimate, not a medical device.** Detection is heuristic. Sleep stages (deep/REM/light) are deliberately not estimated, because a phone's sensors can't measure them reliably.

## Features

- **Hands-free detection**: a per-minute state machine (`awake → possibleSleep → sleeping → possibleWake`) driven by burst-sampled accelerometer and gyroscope data, screen and unlock events, light, proximity and charging.
- **Survives the night**: runs in a headless `flutter_background_service` isolate, with a 15-minute WorkManager fallback that closes stale sessions.
- **Self-repairing history**: on app start and resume it closes sessions the user has clearly woken from, corrects late wake times from screen history, and can fill a missed night from Android usage stats.
- **Analysis**: sleep efficiency, awakenings, longest continuous sleep, a 0–100 quality score, consistency, and personalised tips.
- **Learns the user's schedule**: a circadian profile built from past nights tunes detection sensitivity.
- **Health Connect import** (optional): pulls sleep sessions recorded by wearables and other apps.
- **Your data stays on the device**: stored in a local SQLite file, with nothing sent anywhere. Export to CSV or JSON.

## Platform support

| Android | iOS |
|:-:|:-:|
| ✅ API 26+ | ❌ not yet. iOS doesn't allow continuous overnight background sensing |

## Installation

```yaml
dependencies:
  auto_sleep_tracker:
    git:
      url: https://github.com/mohas7im/auto_sleep_tracker.git
```

### Android setup

1. **`android/app/build.gradle.kts`**: set `minSdk = 26`.

2. **`MainActivity.kt`**: extend `FlutterFragmentActivity` (the Health Connect permission flow needs it):

   ```kotlin
   class MainActivity : FlutterFragmentActivity()
   ```

3. **`AndroidManifest.xml`**: add the permissions and the service type:

   ```xml
   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
       xmlns:tools="http://schemas.android.com/tools">

       <!-- Required -->
       <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>
       <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
       <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
       <uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH"/>
       <uses-permission android:name="android.permission.WAKE_LOCK"/>
       <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>

       <!-- Optional: ask to be exempt from battery optimization -->
       <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
       <!-- Optional: screen history, used to repair missed or late-closed nights -->
       <uses-permission android:name="android.permission.PACKAGE_USAGE_STATS"
           tools:ignore="ProtectedPermissions"/>
       <!-- Optional: Health Connect sleep import -->
       <uses-permission android:name="android.permission.health.READ_SLEEP"/>

       <application ...>
           ...
           <!-- Android 14+ needs a type on the overnight foreground service -->
           <service
               android:name="id.flutter.flutter_background_service.BackgroundService"
               android:foregroundServiceType="health"/>
       </application>
   </manifest>
   ```

See [`example/android/app/src/main/AndroidManifest.xml`](example/android/app/src/main/AndroidManifest.xml) for a complete manifest.

## Usage

```dart
import 'package:auto_sleep_tracker/auto_sleep_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AutoSleepTracker.initialize(
    notificationTitle: 'Sleep tracking',
    onSleepFinishedInBackground: onSleepFinished, // optional
  );
  runApp(const MyApp());
}

// Runs in the background isolate when a night ends, even with the app closed.
@pragma('vm:entry-point')
void onSleepFinished(SleepFinishedEvent night) {
  // e.g. show a "You slept 7h 12m" notification
}
```

In your first screen:

```dart
late final AppLifecycleListener _lifecycle;

@override
void initState() {
  super.initState();
  AutoSleepTracker.onAppStart(); // repairs state, restarts tracking if enabled
  _lifecycle = AppLifecycleListener(onResume: () async {
    if (await AutoSleepTracker.onAppResumed()) reload();
  });
}
```

Turn tracking on and off:

```dart
await AutoSleepTracker.requestPermissions();
await AutoSleepTracker.enable();
// ...
await AutoSleepTracker.disable();
```

Read the history:

```dart
final repo = AutoSleepTracker.repository;
final nights = await repo.getRecentSessions(days: 7);
final ongoing = await repo.getOngoingSession();

final epochs = await repo.getEpochsForSession(nights.first.id);
final analysis = SleepAnalysisEngine.analyze(
  session: nights.first,
  epochs: epochs,
  targetHours: 8,
);
```

Nights that end while your UI is open also arrive on `AutoSleepTracker.onSleepFinished`.

### Tuning

```dart
await SleepDetectionService.setSensitivityProfile(SensitivityProfile.softMattressOrPartner);
await SleepDetectionService.setNightWindowStartHour(21);
await SleepDetectionService.setNightWindowEndHour(10);
await SleepDetectionService.setSleepTargetHours(8);
await SleepDetectionService.setNapModeEnabled(true);
```

### Merging manual sleep logs

If your app lets users log sleep by hand, pass it in. Manual entries override auto-detected sessions for the same night:

```dart
await AutoSleepTracker.initialize(
  manualSessions: () async => myLogs.map((log) => SleepSession.fromManualEntry(
    id: log.id,
    date: log.date,          // 'YYYY-MM-DD'
    bedtime: log.bedtime,    // 'HH:mm'
    wakeTime: log.wakeTime,  // 'HH:mm'
    durationHours: log.hours,
    qualityRating: log.rating,
    factors: const [],
    notes: '',
    createdAt: log.createdAtMs,
  )).toList(),
);
```

### Apps that already use WorkManager

WorkManager allows one dispatcher per app. Pass `initializeWorkManager: false` and route the package's tasks from your own dispatcher:

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, data) async {
    final handled = await handleSleepBackgroundTask(task);
    if (handled != null) return handled;
    // ... your own tasks
    return true;
  });
}
```

### Using your own database

Sleep data goes in its own `auto_sleep_tracker.db` by default. To keep it in your app's database, call `SleepDatabase.createTable` and `SleepDatabase.createEpochTable` from your `onCreate`, then use `SleepRepository(database: () async => myDb)`.

## How it works

```
 Awake ──[still, dark, screen off]──► PossibleSleep
 PossibleSleep ──[25 min sustained]──► Sleeping
 Sleeping ──[motion / screen / unlock / walking]──► PossibleWake
 PossibleWake ──[5 min sustained, or clearly got up]──► Awake
 PossibleWake ──[still again]──► Sleeping      (brief awakening)
```

Each minute the background service:
1. Samples the accelerometer and gyroscope for 12 seconds (burst sampling, never continuous).
2. Reads charging state, light, proximity, step activity and screen/unlock events.
3. Feeds a `SensorSnapshot` to the pure, I/O-free `SleepStateMachine`.
4. Stores a per-minute `SleepEpoch` and the session boundaries in SQLite.

The state machine has no I/O, so you can unit-test it end to end (see [`test/sleep_state_machine_test.dart`](test/sleep_state_machine_test.dart)).

## Reliability tips

Aggressive battery managers on some phones (Xiaomi, Oppo, Vivo, Samsung and others) kill background services. For the best results:
- Ask users to exempt the app from battery optimization (`SleepSignals.requestBatteryOptimizationExemption()`).
- Show `AutoSleepTracker.checkCapabilities()` issues in your settings screen.
- See [dontkillmyapp.com](https://dontkillmyapp.com) for per-manufacturer steps.

## Example

[`example/`](example/) is a small app with an on/off switch, permission warnings and the last 14 nights.

```sh
cd example
flutter run
```

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
