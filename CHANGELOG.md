## 0.2.0

* `SleepRepository.deleteAllData()` to wipe all tracked sleep (e.g. on sign-out).
* `onBackgroundStart` option in `SleepSense.initialize` to configure the package inside background isolates.

## 0.1.0

* Initial release.
* Automatic overnight sleep detection from motion, screen, unlock, light, proximity and charging signals.
* Background service plus WorkManager fallback; startup and resume recovery.
* Session analysis, quality score and circadian pattern learning.
* Optional Health Connect import and manual-log merging.
