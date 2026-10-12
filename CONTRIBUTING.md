# Contributing

Thanks for helping improve auto_sleep_tracker!

## Development

```sh
flutter pub get
flutter analyze
flutter test
```

To try changes on a device:

```sh
cd example
flutter run
```

## Guidelines

- **Keep the state machine pure.** `SleepStateMachine` must stay free of I/O and plugins so it can be tested with plain `SensorSnapshot`s. Add a test in `test/sleep_state_machine_test.dart` for any change to detection behaviour, ideally written as a realistic night scenario.
- **Battery first.** The service wakes every minute all night. Avoid continuous sensor streams and keep per-tick work small.
- **Privacy.** Nothing leaves the device. Don't add network calls or analytics.
- Run `flutter analyze` and `flutter test` before opening a pull request.

## Reporting detection problems

Detection bugs are hard to reproduce, so please include:
- Phone model and Android version
- Where the phone was (bed, nightstand, charging?)
- The diagnostic log from `SleepDetectionLogger().exportFormattedText()`
