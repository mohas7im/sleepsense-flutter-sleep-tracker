import 'package:auto_sleep_tracker/src/sleep_recovery_manager.dart';
import 'package:flutter_test/flutter_test.dart';

ScreenEvent on(DateTime t) => (at: t, type: ScreenEventType.screenOn);
ScreenEvent off(DateTime t) => (at: t, type: ScreenEventType.screenOff);
ScreenEvent unlock(DateTime t) => (at: t, type: ScreenEventType.unlock);

void main() {
  DateTime at(int hour, int minute, [int second = 0]) => DateTime(2026, 9, 26, hour, minute, second);
  final findGotUpTime = SleepRecoveryManager.findGotUpTime;

  group('findGotUpTime', () {
    test('first unlock after 5 AM is when the user got up', () {
      final events = [on(at(7, 0)), unlock(at(7, 0, 5)), off(at(7, 0, 20))];
      expect(findGotUpTime(events, until: at(9, 0)), at(7, 0));
    });

    test('an unlock at 3 AM is only a night awakening', () {
      final events = [
        on(at(3, 0)), unlock(at(3, 0, 5)), off(at(3, 1)),
        on(at(6, 45)), unlock(at(6, 45, 3)), off(at(6, 50)),
      ];
      expect(findGotUpTime(events, until: at(9, 0)), at(6, 45));
    });

    test('a short glance without unlocking is not getting up', () {
      final events = [on(at(6, 30)), off(at(6, 30, 15)), on(at(7, 15)), off(at(7, 17))];
      expect(findGotUpTime(events, until: at(9, 0)), at(7, 15));
    });

    test('a screen still on at the end counts up to that moment', () {
      final events = [on(at(8, 0))];
      expect(findGotUpTime(events, until: at(8, 0, 30)), isNull);
      expect(findGotUpTime(events, until: at(8, 2)), at(8, 0));
    });

    test('no history means no evidence', () {
      expect(findGotUpTime(const [], until: at(9, 0)), isNull);
    });
  });
}
