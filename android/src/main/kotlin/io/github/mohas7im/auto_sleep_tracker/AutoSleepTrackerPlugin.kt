package io.github.mohas7im.auto_sleep_tracker

import android.app.AppOpsManager
import android.app.KeyguardManager
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Screen, unlock, light, proximity and usage-history signals for sleep
 * tracking.
 *
 * As a plugin it is attached to every Flutter engine, including the headless
 * engine flutter_background_service runs overnight, so sleep detection there
 * can see the user waking up. Uses the application context, so it works
 * without an Activity.
 *
 * Events: "SCREEN_ON", "SCREEN_OFF", "USER_PRESENT" (device unlocked).
 */
class AutoSleepTrackerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var receiver: BroadcastReceiver? = null
    private val handler = Handler(Looper.getMainLooper())
    private val backgroundExecutor = Executors.newSingleThreadExecutor()

    // USER_PRESENT isn't delivered reliably on every device, so after the
    // screen turns on the keyguard is also watched. Either path reports one
    // unlock per screen-on.
    private var unlockReported = false
    private var keyguardPoll: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "auto_sleep_tracker")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "auto_sleep_tracker/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        unregister()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Snapshot for when the stream starts mid-state (e.g. service restart).
            "getState" -> {
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(
                    mapOf(
                        "screenOn" to power.isInteractive,
                        "locked" to keyguard().isKeyguardLocked,
                    )
                )
            }
            "readLight" -> readOnce(Sensor.TYPE_LIGHT, result, noSensor = -1.0) { event, _ ->
                event.values[0].toDouble()
            }
            "readProximity" -> readOnce(Sensor.TYPE_PROXIMITY, result, noSensor = null) { event, sensor ->
                event.values[0] < sensor.maximumRange
            }
            "hasUsagePermission" -> result.success(hasUsageAccess())
            "openUsageSettings" -> {
                openSettings(Settings.ACTION_USAGE_ACCESS_SETTINGS, withPackage = true)
                result.success(true)
            }
            "isBatteryOptimizationExempt" -> {
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(power.isIgnoringBatteryOptimizations(context.packageName))
            }
            "requestIgnoreBatteryOptimizations" -> {
                // Needs REQUEST_IGNORE_BATTERY_OPTIMIZATIONS in the app's
                // manifest; without it, fall back to the settings list.
                if (!openSettings(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, withPackage = true)) {
                    openSettings(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS, withPackage = false)
                }
                result.success(true)
            }
            // Screen on/off and unlock history (empty without usage access).
            // Used to find when the user got up after a sleep session.
            "getScreenEvents" -> {
                val startMs = call.argument<Number>("startMs")!!.toLong()
                val endMs = call.argument<Number>("endMs")!!.toLong()
                runInBackground(result, "SCREEN_EVENTS_ERROR") {
                    UsageHistory.screenEvents(usageStats(), startMs, endMs)
                }
            }
            "getOvernightInactivityWindow" -> {
                val targetDateMs = call.argument<Number>("targetDateMs")?.toLong() ?: System.currentTimeMillis()
                val nightStartHour = call.argument<Int>("nightStartHour") ?: 20
                val nightEndHour = call.argument<Int>("nightEndHour") ?: 12
                runInBackground(result, "INACTIVITY_WINDOW_ERROR") {
                    UsageHistory.overnightInactivityWindow(
                        usageStats(), context.packageManager, targetDateMs, nightStartHour, nightEndHour,
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun usageStats() = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager

    private fun runInBackground(result: MethodChannel.Result, errorCode: String, work: () -> Any?) {
        backgroundExecutor.execute {
            try {
                val value = work()
                handler.post { result.success(value) }
            } catch (e: Exception) {
                handler.post { result.error(errorCode, e.message, null) }
            }
        }
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** Opens a settings screen, optionally for this app. Returns false if none could open. */
    private fun openSettings(action: String, withPackage: Boolean): Boolean {
        val attempts = if (withPackage) listOf(true, false) else listOf(false)
        for (forPackage in attempts) {
            try {
                val intent = Intent(action).apply {
                    if (forPackage) data = Uri.parse("package:${context.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    /**
     * Reads one value from [type]. On-change sensors (light, proximity) report
     * their current value right after registering; if nothing arrives within
     * [READ_TIMEOUT_MS] the answer is [noSensor], so a tick never hangs.
     */
    private fun readOnce(
        type: Int,
        result: MethodChannel.Result,
        noSensor: Any?,
        value: (SensorEvent, Sensor) -> Any,
    ) {
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = sm.getDefaultSensor(type)
        if (sensor == null) {
            result.success(noSensor)
            return
        }
        var answered = false
        lateinit var listener: SensorEventListener
        val timeout = Runnable {
            if (!answered) {
                answered = true
                sm.unregisterListener(listener)
                result.success(noSensor)
            }
        }
        listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (answered) return
                answered = true
                handler.removeCallbacks(timeout)
                sm.unregisterListener(this)
                result.success(value(event, sensor))
            }
            override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
        }
        sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL, handler)
        handler.postDelayed(timeout, READ_TIMEOUT_MS)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        unregister()

        fun reportUnlock() {
            if (unlockReported) return
            unlockReported = true
            stopKeyguardPoll()
            events.success("USER_PRESENT")
        }

        val newReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> {
                        events.success("SCREEN_ON")
                        unlockReported = false
                        startKeyguardPoll(::reportUnlock)
                    }
                    Intent.ACTION_SCREEN_OFF -> {
                        stopKeyguardPoll()
                        events.success("SCREEN_OFF")
                    }
                    Intent.ACTION_USER_PRESENT -> reportUnlock()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        // System broadcasts still reach a not-exported receiver.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(newReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(newReceiver, filter)
        }
        receiver = newReceiver
    }

    /** Polls the keyguard while the screen is on and reports when it unlocks. */
    private fun startKeyguardPoll(onUnlock: () -> Unit) {
        stopKeyguardPoll()
        // Screen came on already unlocked (e.g. smart lock): nothing to wait for.
        if (!keyguard().isKeyguardLocked) return
        val startedAt = System.currentTimeMillis()
        val poll = object : Runnable {
            override fun run() {
                if (!keyguard().isKeyguardLocked) {
                    onUnlock()
                } else if (System.currentTimeMillis() - startedAt < KEYGUARD_POLL_MAX_MS) {
                    handler.postDelayed(this, KEYGUARD_POLL_INTERVAL_MS)
                }
            }
        }
        keyguardPoll = poll
        handler.postDelayed(poll, KEYGUARD_POLL_INTERVAL_MS)
    }

    private fun stopKeyguardPoll() {
        keyguardPoll?.let { handler.removeCallbacks(it) }
        keyguardPoll = null
    }

    private fun keyguard() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    override fun onCancel(arguments: Any?) {
        unregister()
    }

    private fun unregister() {
        stopKeyguardPoll()
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
    }

    private companion object {
        const val READ_TIMEOUT_MS = 1500L
        const val KEYGUARD_POLL_INTERVAL_MS = 1000L
        const val KEYGUARD_POLL_MAX_MS = 60_000L
    }
}
