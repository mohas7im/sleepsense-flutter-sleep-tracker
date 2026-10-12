import 'package:flutter/services.dart';

/// A change in screen / lock state reported by the device.
enum SleepSignalEvent { screenOn, screenOff, unlocked }

/// Device signals from this package's native Android plugin, available in
/// every Flutter engine — including the headless background-service engine
/// used for overnight sleep tracking.
class SleepSignals {
  SleepSignals._();

  /// Shared with the other parts of the package that talk to the plugin.
  static const channel = MethodChannel('auto_sleep_tracker');
  static const _events = EventChannel('auto_sleep_tracker/events');

  static const _eventNames = {
    'SCREEN_ON': SleepSignalEvent.screenOn,
    'SCREEN_OFF': SleepSignalEvent.screenOff,
    'USER_PRESENT': SleepSignalEvent.unlocked,
  };

  /// Screen on/off and unlock events as they happen.
  static Stream<SleepSignalEvent> get events =>
      _events.receiveBroadcastStream().map((name) => _eventNames[name]!);

  /// Current state, for starting up in the middle of a screen-on period.
  static Future<({bool screenOn, bool locked})> currentState() async {
    final state = await channel.invokeMapMethod<String, bool>('getState');
    return (screenOn: state!['screenOn']!, locked: state['locked']!);
  }

  /// Current ambient light in lux, or null when the device has no light
  /// sensor or it didn't answer in time.
  static Future<double?> readLight() async {
    final lux = await channel.invokeMethod<double>('readLight');
    return lux == null || lux < 0 ? null : lux;
  }

  /// Whether something is covering the proximity sensor (face-down, in a
  /// pocket), or null when there is no proximity sensor.
  static Future<bool?> readProximity() => channel.invokeMethod<bool>('readProximity');

  /// Whether the user granted Usage Access, which the overnight-history
  /// features ([SleepRecoveryManager]) need to read past screen events.
  static Future<bool> hasUsageAccess() async =>
      await channel.invokeMethod<bool>('hasUsagePermission') ?? false;

  /// Opens the system Usage Access settings page for this app.
  static Future<void> openUsageAccessSettings() => channel.invokeMethod('openUsageSettings');

  /// Whether the app is exempt from battery optimization (Doze).
  static Future<bool> isBatteryOptimizationExempt() async =>
      await channel.invokeMethod<bool>('isBatteryOptimizationExempt') ?? false;

  /// Asks the system to exempt this app from battery optimization. Needs the
  /// `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission in the app manifest;
  /// without it the battery settings list opens instead.
  static Future<void> requestBatteryOptimizationExemption() =>
      channel.invokeMethod('requestIgnoreBatteryOptimizations');
}
