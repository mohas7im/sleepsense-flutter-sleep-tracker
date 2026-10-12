import 'package:sleep_sense/src/sleep_repository.dart';
import 'package:sleep_sense/src/sleep_session.dart';
import 'package:flutter_test/flutter_test.dart';

SleepSession _session(
  String id,
  DateTime start,
  DateTime end, {
  String source = SleepSession.sourcePhoneHeuristic,
}) =>
    SleepSession(
      id: id,
      sleepStartMs: start.millisecondsSinceEpoch,
      wakeTimeMs: end.millisecondsSinceEpoch,
      durationMinutes: end.difference(start).inMinutes,
      confidenceScore: 80,
      isAutomatic: true,
      createdAt: 0,
      source: source,
    );

void main() {
  group('SleepRepository.dedupeOverlappingAuto', () {
    test('keeps Health Connect over an overlapping phone-heuristic session', () {
      final phone = _session('phone', DateTime(2026, 9, 24, 23, 10), DateTime(2026, 9, 25, 7, 40));
      final hc = _session('hc', DateTime(2026, 9, 24, 23, 30), DateTime(2026, 9, 25, 6, 50),
          source: SleepSession.sourceHealthConnect);

      final result = SleepRepository.dedupeOverlappingAuto([phone, hc]);

      expect(result.map((s) => s.id), ['hc']);
    });

    test('keeps the longer of two overlapping phone sessions', () {
      final live = _session('live', DateTime(2026, 9, 24, 23, 0), DateTime(2026, 9, 25, 3, 0));
      final synced = _session('synced', DateTime(2026, 9, 24, 23, 5), DateTime(2026, 9, 25, 7, 0));

      final result = SleepRepository.dedupeOverlappingAuto([live, synced]);

      expect(result.map((s) => s.id), ['synced']);
    });

    test('keeps a night and a separate nap on the same day', () {
      final night = _session('night', DateTime(2026, 9, 24, 23, 0), DateTime(2026, 9, 25, 7, 0));
      final nap = _session('nap', DateTime(2026, 9, 25, 14, 0), DateTime(2026, 9, 25, 15, 0));

      final result = SleepRepository.dedupeOverlappingAuto([night, nap]);

      expect(result.map((s) => s.id).toSet(), {'night', 'nap'});
    });
  });
}
