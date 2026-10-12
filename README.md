# SleepSense 🌙

[![CI](https://github.com/mohas7im/SleepSense/actions/workflows/ci.yml/badge.svg)](https://github.com/mohas7im/SleepSense/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Android](https://img.shields.io/badge/platform-Android-3DDC84.svg)

**Automatic sleep tracking for Flutter apps. No smartwatch, no "I'm going to bed" button. The phone works it out on its own.**

Add SleepSense to your app, turn it on once, and every morning your app knows:

- 🛏️ when the user fell asleep
- ⏰ when they woke up
- 📊 how well they slept (a 0–100 score, awakenings, sleep efficiency)

---

## How does it know I'm asleep?

Your phone already has sensors that tell a lot about what you're doing. SleepSense checks them once a minute, all night:

| Signal | What it tells us |
|---|---|
| 📳 **Motion** (accelerometer, gyroscope) | Is the phone lying still on the bed or nightstand? |
| 📱 **Screen and unlocks** | Is the user still scrolling, or has the phone been untouched for a while? |
| 💡 **Light** | Is the room dark? |
| 🔌 **Charging** | Most people plug in at bedtime and unplug in the morning. |
| 🚶 **Steps** | Is the user walking around (awake)? |
| 🕒 **Time of day** | Learns the user's usual bedtime and gets more confident around it. |

When the phone has been still, dark and unused for about 25 minutes, SleepSense decides the user is asleep. When they pick up the phone, unlock it or walk around in the morning, it records the wake-up time.

> ⚠️ **This is a wellness feature, not a medical device.** The results are good estimates, not clinical measurements. SleepSense doesn't guess sleep stages (deep, REM, light), because phone sensors can't measure them reliably.

---

## Features

- ✅ **Fully automatic**: no buttons and no wearable needed.
- ✅ **Works with the app closed**: tracking keeps running even after the user swipes the app away.
- ✅ **Fixes its own mistakes**: if the phone killed tracking overnight, SleepSense repairs the night from the phone's screen history next time the app opens.
- ✅ **Sleep analysis**: quality score, awakenings, longest unbroken sleep, consistency and tips.
- ✅ **Morning callback**: run your own code (e.g. a "You slept 7h 20m" notification) the moment the user wakes up.
- ✅ **Health Connect** (optional): import sleep recorded by smartwatches and other apps.
- ✅ **Private**: everything stays in a local database on the phone. Nothing is uploaded.
- ✅ **Battery friendly**: reads sensors in short 12-second bursts, never continuously.

---

## Requirements

| | |
|---|---|
| Platform | **Android 8.0+** (API 26). iOS is not supported, because it doesn't allow apps to read sensors all night in the background. |
| Flutter | 3.27 or newer |

---

## Getting started

### 1. Add the package

In your app's `pubspec.yaml`:

```yaml
dependencies:
  sleep_sense:
    git:
      url: https://github.com/mohas7im/SleepSense.git
```

Then run `flutter pub get`.

### 2. Set up Android

**a) Minimum Android version.** In `android/app/build.gradle.kts`:

```kotlin
defaultConfig {
    minSdk = 26
}
```

**b) Main activity.** In `android/app/src/main/kotlin/.../MainActivity.kt`, change `FlutterActivity` to `FlutterFragmentActivity`:

```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

**c) Permissions.** In `android/app/src/main/AndroidManifest.xml`:

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

    <!-- Recommended: lets you ask Android not to stop tracking to save battery -->
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

    <!-- Optional: lets SleepSense repair nights it missed -->
    <uses-permission android:name="android.permission.PACKAGE_USAGE_STATS"
        tools:ignore="ProtectedPermissions"/>

    <!-- Optional: import sleep from Health Connect -->
    <uses-permission android:name="android.permission.health.READ_SLEEP"/>

    <application ...>
        ...
        <!-- Required: the service that tracks sleep overnight -->
        <service
            android:name="id.flutter.flutter_background_service.BackgroundService"
            android:foregroundServiceType="health"/>
    </application>
</manifest>
```

💡 For a complete working setup, see the [example app's manifest](example/android/app/src/main/AndroidManifest.xml).

### 3. Start SleepSense

In `main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:sleep_sense/sleep_sense.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SleepSense.initialize();
  runApp(const MyApp());
}
```

When your first screen opens:

```dart
@override
void initState() {
  super.initState();
  SleepSense.onAppStart();
}
```

### 4. Let the user turn it on

```dart
// e.g. in a "Track my sleep automatically" switch
await SleepSense.requestPermissions();
await SleepSense.enable();
```

That's it. Tonight's sleep will be recorded. 🎉

### 5. Show the results

```dart
final nights = await SleepSense.repository.getRecentSessions(days: 7);

for (final night in nights) {
  print('${night.canonicalDateString}: ${night.durationLabel} '
        '(${night.bedtimeLabel} → ${night.wakeTimeLabel})');
}
// 2026-10-11: 7h 24m (11:42 PM → 7:06 AM)
```

---

## Common tasks

### Is the user asleep right now?

```dart
final ongoing = await SleepSense.repository.getOngoingSession();
if (ongoing != null) print('Asleep since ${ongoing.bedtimeLabel}');
```

### Get a detailed analysis of one night

```dart
final night = nights.first;
final epochs = await SleepSense.repository.getEpochsForSession(night.id);

final analysis = SleepAnalysisEngine.analyze(
  session: night,
  epochs: epochs,
  targetHours: 8,
);
```

### Send a "good morning" notification

Pass a function to `initialize`. It runs when the user wakes up, **even if your app is closed**:

```dart
await SleepSense.initialize(onSleepFinishedInBackground: onWakeUp);

// Must be a top-level function (outside any class) with this annotation.
@pragma('vm:entry-point')
void onWakeUp(SleepFinishedEvent night) {
  // Show your notification here, e.g. with flutter_local_notifications.
  // night.durationMinutes, night.sleepScore, night.sleepStart, night.wakeTime
}
```

If your app is open at the time, you can also listen to `SleepSense.onSleepFinished`.

### Refresh when the user comes back to the app

```dart
AppLifecycleListener(onResume: () async {
  final changed = await SleepSense.onAppResumed();
  if (changed) reloadMyScreen();
});
```

### Turn tracking off

```dart
await SleepSense.disable();
```

### Adjust for the user

```dart
// Soft mattress or sharing the bed? Be less sensitive to movement.
await SleepDetectionService.setSensitivityProfile(SensitivityProfile.softMattressOrPartner);

// Hours when night-time sleep is expected (24h clock)
await SleepDetectionService.setNightWindowStartHour(21); // 9 PM
await SleepDetectionService.setNightWindowEndHour(10);   // 10 AM

// Sleep goal used in scores
await SleepDetectionService.setSleepTargetHours(8);

// Also detect daytime naps
await SleepDetectionService.setNapModeEnabled(true);
```

### Export data

```dart
final csv = await SleepSense.repository.exportSessionsToCSV(days: 30);
final json = await SleepSense.repository.exportSessionsToJSON(days: 30);
```

---

## Making tracking reliable

Some phone brands (Xiaomi, Oppo, Vivo, Samsung and others) aggressively close background apps to save battery, which can stop sleep tracking at night. To avoid this:

1. **Ask to be excluded from battery optimization:**
   ```dart
   final report = await SleepSense.checkCapabilities();
   if (report.isExemptFromBatteryOptimization == false) {
     await SleepSignals.requestBatteryOptimizationExemption();
   }
   ```
2. **Show the user what's missing.** `report.issues` is a list of plain-English problems (missing permissions and so on) that you can display in your settings screen.
3. **Point users to [dontkillmyapp.com](https://dontkillmyapp.com)** for brand-specific steps.

---

## Advanced

<details>
<summary><b>Merge sleep the user logged by hand</b></summary>

If your app also lets users log sleep manually, pass those entries in. A manual entry replaces the automatic one for the same night.

```dart
await SleepSense.initialize(
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

Tracking runs in a background isolate that doesn't run your `main()`. To let it see manual logs too (they help it learn the user's schedule), set them again in `onBackgroundStart`:

```dart
await SleepSense.initialize(
  manualSessions: loadMyManualSleep,
  onBackgroundStart: setUpSleepBackground,
);

@pragma('vm:entry-point')
Future<void> setUpSleepBackground() async {
  SleepRepository.defaultManualSessions = loadMyManualSleep;
}
```
</details>

<details>
<summary><b>Your app already uses WorkManager</b></summary>

Android allows only one WorkManager dispatcher per app. Tell SleepSense not to set one up, and forward its tasks from yours:

```dart
await SleepSense.initialize(initializeWorkManager: false);

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
</details>

<details>
<summary><b>Store sleep data in your own database</b></summary>

By default SleepSense keeps its data in its own file, `sleep_sense.db`. To use your app's sqflite database instead, create the tables in your `onCreate`:

```dart
await SleepDatabase.createTable(db);
await SleepDatabase.createEpochTable(db);
```

Then use `SleepRepository(database: () async => myDatabase)`.
</details>

<details>
<summary><b>How the detection works internally</b></summary>

Each minute, the background service:

1. Reads the accelerometer and gyroscope for 12 seconds.
2. Reads charging state, light, proximity, steps and screen/unlock events.
3. Passes this snapshot to `SleepStateMachine`.
4. Saves a one-minute record (`SleepEpoch`) and the sleep session to SQLite.

The state machine moves between four states:

```
 Awake ──(still, dark, screen off)──► Possibly asleep
 Possibly asleep ──(25 minutes)──► Asleep
 Asleep ──(movement / screen / unlock / walking)──► Possibly awake
 Possibly awake ──(5 minutes, or clearly got up)──► Awake
 Possibly awake ──(still again)──► Asleep   (just a brief awakening)
```

The state machine has no I/O, so it can be fully unit-tested. See [`test/sleep_state_machine_test.dart`](test/sleep_state_machine_test.dart) for realistic night scenarios.
</details>

---

## FAQ

**Does it drain the battery?**
Very little. Sensors are read in short bursts once a minute, not continuously, and most people charge overnight anyway.

**Does the phone need to be in the bed?**
No. A nightstand works. In the bed or under the pillow gives better movement detection.

**What if the user doesn't take their phone to bed?**
SleepSense can't track that night, unless they wear a watch that writes to Health Connect and you enable the Health Connect import.

**Is any data sent to a server?**
No. Everything stays on the device.

**Why no iOS?**
iOS doesn't let apps run a background service that reads sensors all night. iOS support would need a different approach. Contributions are welcome.

---

## Try the example app

The [`example/`](example/) folder has a small app with an on/off switch, permission warnings and a list of recent nights:

```sh
cd example
flutter run
```

---

## Contributing

Bug reports, ideas and pull requests are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

If sleep was detected wrongly, please open an issue with your phone model and the diagnostic log from `SleepDetectionLogger().exportFormattedText()`.

## License

[MIT](LICENSE). Free to use in personal and commercial apps.
