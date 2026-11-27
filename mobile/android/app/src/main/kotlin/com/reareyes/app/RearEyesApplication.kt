package com.reareyes.app

import android.app.Activity
import android.app.Application
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

internal class RearEyesApplication : Application(), MainActivity.RearEyeFactory {
    override fun createRearEyes(activity: Activity, chrome: EyesView): MainActivity.RearEyeSurface =
        FlutterRearEyes(activity, chrome)
}

private class FlutterRearEyes(
    private val activity: Activity,
    private val chrome: EyesView,
) : MainActivity.RearEyeSurface {
    private val engine = FlutterEngine(activity.applicationContext, null, false)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.reareyes/rear-eyes")
    override val view = FlutterView(activity, FlutterTextureView(activity))
    private val handler = Handler(Looper.getMainLooper())
    private var lastSnapshot: Map<String, Any?>? = null
    private val refresh = object : Runnable {
        override fun run() {
            if (view.isShown && view.windowVisibility == View.VISIBLE) {
                val current = snapshot()
                if (current != lastSnapshot) {
                    lastSnapshot = current
                    channel.invokeMethod("update", current)
                }
            }
            handler.postDelayed(this, 100)
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "subscribe" -> {
                    val current = snapshot()
                    lastSnapshot = current
                    result.success(current)
                    handler.removeCallbacks(refresh)
                    handler.post(refresh)
                }
                "noticeIcon" -> {
                    val source = call.arguments as? String
                    result.success(source?.let { RobotInteractionBridge.appIconBytes(activity, it) })
                }
                "wake" -> {
                    (call.arguments as? Number)?.toLong()?.let(EyesBus::wakeFromSleep)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val assets = io.flutter.FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(assets, "rearEyesMain"))
        view.attachToFlutterEngine(engine)
        engine.lifecycleChannel.appIsResumed()
    }

    private fun snapshot(): Map<String, Any?> {
        val now = SystemClock.elapsedRealtime()
        val voice = EyesBus.rearVoice
        val status = EyesBus.state
        val greetedAt = EyesBus.greetedAt
        val greeting = now - greetedAt in 0L until 1400L && greetedAt > 0L &&
            EyesBus.stateSince <= greetedAt && status != EyeState.QUESTION && status != EyeState.ERROR
        val mood = when {
            voice?.phase == EyesBus.VoicePhase.THINKING -> "THINKING"
            voice?.phase == EyesBus.VoicePhase.LISTENING -> "FOCUS"
            voice != null || greeting -> "HELLO"
            else -> status.name
        }
        val sleep = EyesBus.sleepSession()
        return mapOf(
            "mood" to mood,
            "revision" to EyesBus.stateSince,
            "sleepRevision" to sleep?.revision,
            "sleepSeconds" to SleepSettings.load(activity),
            "keepAwake" to chrome.keepAwake,
            "conversationActive" to (voice != null),
            "voiceLevel" to voice?.level?.toDouble()?.takeIf { voice.phase == EyesBus.VoicePhase.LISTENING },
            "speechActivity" to (voice?.activity ?: 0),
            "speaking" to (voice?.phase == EyesBus.VoicePhase.SPEAKING),
            "notices" to EyesBus.recentRearNotices(now).map { notice ->
                mapOf(
                    "key" to notice.key,
                    "source" to notice.source,
                    "title" to notice.title,
                    "text" to notice.text,
                    "package" to notice.packageName,
                    "verification" to notice.verification,
                    "receivedAt" to notice.receivedAt,
                )
            },
            "noticeCue" to EyesBus.rearNotice?.takeIf { it.react && now - it.startedAt < 1050 }?.key,
            "leftInset" to chrome.rearEyeInset().toDouble() / activity.resources.displayMetrics.density,
        )
    }

    override fun close() {
        handler.removeCallbacks(refresh)
        channel.setMethodCallHandler(null)
        engine.lifecycleChannel.appIsDetached()
        view.detachFromFlutterEngine()
        engine.destroy()
    }
}
