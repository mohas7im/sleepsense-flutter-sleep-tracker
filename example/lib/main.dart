import 'dart:async';

import 'package:sleep_sense/sleep_sense.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SleepSense.initialize(
    notificationTitle: 'Sleep tracking',
    notificationContent: 'Watching for sleep tonight',
    onSleepFinishedInBackground: onSleepFinishedInBackground,
  );
  runApp(const ExampleApp());
}

/// Runs in the background isolate when a night ends, even with the app
/// closed. A real app would show a morning summary notification here.
@pragma('vm:entry-point')
void onSleepFinishedInBackground(SleepFinishedEvent event) {
  debugPrint('Slept ${event.durationMinutes} min (score ${event.sleepScore})');
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SleepSense',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const SleepHomePage(),
    );
  }
}

class SleepHomePage extends StatefulWidget {
  const SleepHomePage({super.key});

  @override
  State<SleepHomePage> createState() => _SleepHomePageState();
}

class _SleepHomePageState extends State<SleepHomePage> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<SleepFinishedEvent>? _finished;

  bool _enabled = false;
  OSCapabilityReport? _capabilities;
  SleepSession? _ongoing;
  List<SleepSession> _nights = const [];

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _finished = SleepSense.onSleepFinished.listen((_) => _reload());
    _start();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _finished?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    await SleepSense.onAppStart();
    await _reload();
  }

  Future<void> _onResume() async {
    if (await SleepSense.onAppResumed()) await _reload();
  }

  Future<void> _reload() async {
    final repo = SleepSense.repository;
    final enabled = await SleepSense.isEnabled();
    final capabilities = await SleepSense.checkCapabilities();
    final ongoing = await repo.getOngoingSession();
    final nights = await repo.getRecentSessions(days: 14);
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _capabilities = capabilities;
      _ongoing = ongoing;
      _nights = nights;
    });
  }

  Future<void> _setEnabled(bool on) async {
    if (on) {
      await SleepSense.requestPermissions();
      await SleepSense.enable();
    } else {
      await SleepSense.disable();
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final issues = _capabilities?.issues ?? const <String>[];
    return Scaffold(
      appBar: AppBar(title: const Text('SleepSense')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: SwitchListTile(
                title: const Text('Automatic sleep tracking'),
                subtitle: Text(_ongoing == null
                    ? 'Detects sleep from motion, screen and charging'
                    : 'Asleep since ${_ongoing!.bedtimeLabel}'),
                value: _enabled,
                onChanged: _setEnabled,
              ),
            ),
            for (final issue in issues)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.warning_amber_rounded),
                  title: Text(issue),
                ),
              ),
            if (_capabilities?.isExemptFromBatteryOptimization == false)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.battery_alert),
                  title: const Text('Allow tracking to run all night'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: SleepSignals.requestBatteryOptimizationExemption,
                ),
              ),
            const SizedBox(height: 16),
            Text('Last 14 nights', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_nights.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No sleep recorded yet. Turn tracking on and sleep with your phone nearby.'),
              ),
            for (final night in _nights)
              Card(
                child: ListTile(
                  leading: Icon(night.isNap ? Icons.wb_sunny_outlined : Icons.bedtime_outlined),
                  title: Text(night.durationLabel),
                  subtitle: Text('${night.canonicalDateString} · ${night.bedtimeLabel} → ${night.wakeTimeLabel}'),
                  trailing: Text(night.sourceBadge),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
