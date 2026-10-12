package io.github.mohas7im.auto_sleep_tracker

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.pm.PackageManager
import java.util.Calendar

/**
 * Past screen activity from Android's usage stats. Every query returns
 * nothing until the user grants Usage Access.
 */
internal object UsageHistory {

    /** Screen on/off and unlock events between [startMs] and [endMs]. */
    fun screenEvents(usm: UsageStatsManager, startMs: Long, endMs: Long): List<Map<String, Any>> {
        val events = usm.queryEvents(startMs, endMs)
        val event = UsageEvents.Event()
        val out = mutableListOf<Map<String, Any>>()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val type = when (event.eventType) {
                UsageEvents.Event.SCREEN_INTERACTIVE -> "screen_on"
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> "screen_off"
                UsageEvents.Event.KEYGUARD_HIDDEN -> "unlock"
                else -> null
            }
            if (type != null) out.add(mapOf("ts" to event.timeStamp, "type" to type))
        }
        return out
    }

    /**
     * The longest stretch the phone sat unused between [nightStartHour] the
     * evening before [targetDateMs] and [nightEndHour] on that day — a
     * fallback estimate of the night's sleep when live tracking missed it.
     */
    fun overnightInactivityWindow(
        usm: UsageStatsManager,
        pm: PackageManager,
        targetDateMs: Long,
        nightStartHour: Int,
        nightEndHour: Int,
    ): Map<String, Any?> {
        val targetDay = Calendar.getInstance().apply {
            timeInMillis = targetDateMs
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val windowStartMs = (targetDay.clone() as Calendar).apply {
            add(Calendar.DAY_OF_YEAR, -1)
            set(Calendar.HOUR_OF_DAY, nightStartHour)
        }.timeInMillis
        val windowEndMs = minOf(
            (targetDay.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, nightEndHour) }.timeInMillis,
            System.currentTimeMillis(),
        )
        if (windowStartMs >= windowEndMs) return mapOf("hasData" to false)

        data class StateTransition(val ts: Long, val isInteractive: Boolean, val pkg: String?)
        val transitions = mutableListOf<StateTransition>()

        val events = usm.queryEvents(windowStartMs, windowEndMs)
        val event = UsageEvents.Event()
        var lastPkg: String? = null
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> lastPkg = event.packageName
                UsageEvents.Event.SCREEN_NON_INTERACTIVE,
                UsageEvents.Event.KEYGUARD_SHOWN,
                UsageEvents.Event.DEVICE_SHUTDOWN -> transitions.add(StateTransition(event.timeStamp, false, lastPkg))
                UsageEvents.Event.KEYGUARD_HIDDEN,
                UsageEvents.Event.SCREEN_INTERACTIVE -> transitions.add(StateTransition(event.timeStamp, true, lastPkg))
            }
        }

        data class InactiveSpan(val startMs: Long, val endMs: Long, val lastAppBefore: String?, val firstAppAfter: String?)
        val spans = mutableListOf<InactiveSpan>()
        var screenOffStart: Long? = null
        var appBeforeSleep: String? = null

        for (t in transitions) {
            if (!t.isInteractive) {
                if (screenOffStart == null) {
                    screenOffStart = t.ts
                    appBeforeSleep = t.pkg
                }
            } else if (screenOffStart != null) {
                if (t.ts - screenOffStart >= MIN_SPAN_MS) {
                    spans.add(InactiveSpan(screenOffStart, t.ts, appBeforeSleep, t.pkg))
                }
                screenOffStart = null
            }
        }
        if (screenOffStart != null && windowEndMs - screenOffStart >= MIN_SPAN_MS) {
            spans.add(InactiveSpan(screenOffStart, windowEndMs, appBeforeSleep, null))
        }

        val primary = spans.maxByOrNull { it.endMs - it.startMs } ?: return mapOf("hasData" to false)
        val durationMinutes = ((primary.endMs - primary.startMs) / 60_000L).toInt()
        if (durationMinutes < MIN_SLEEP_MINUTES) return mapOf("hasData" to false)

        return mapOf(
            "hasData" to true,
            "bedtimeMs" to primary.startMs,
            "wakeTimeMs" to primary.endMs,
            "durationMinutes" to durationMinutes,
            "confidenceScore" to 94,
            "interruptionCount" to 0,
            "interruptionDurationMinutes" to 0,
            "lastAppUsed" to appLabel(pm, primary.lastAppBefore),
            "firstAppUsed" to appLabel(pm, primary.firstAppAfter),
        )
    }

    /** The app's display name, or "" when unknown. */
    private fun appLabel(pm: PackageManager, pkg: String?): String {
        if (pkg.isNullOrEmpty()) return ""
        return try {
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            pkg.substringAfterLast('.').replaceFirstChar { it.uppercase() }
        }
    }

    private const val MIN_SPAN_MS = 60_000L
    private const val MIN_SLEEP_MINUTES = 90
}
