package com.reareyes.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import rikka.shizuku.Shizuku

class FlutterHostActivity : FlutterActivity() {
    private var interaction: RobotInteractionBridge? = null
    private var pendingRear: Boolean? = null
    private val rearPermission = Shizuku.OnRequestPermissionResultListener { request, granted ->
        if (request == SHIZUKU_REQUEST) {
            val calibrate = pendingRear
            pendingRear = null
            if (calibrate != null && !isFinishing && !isDestroyed) {
                if (granted == PackageManager.PERMISSION_GRANTED) launchRear(calibrate)
                else RearDisplayBridge.offerShizuku(this, "请在 Shizuku 的「已授权应用」中允许 Robot Eyes。")
            }
        }
    }

    private fun supportsRear() = Build.MODEL == "2509FPN0BC" &&
        getSystemService(DisplayManager::class.java).getDisplay(1) != null

    private fun requestRear(calibrate: Boolean) {
        if (!supportsRear()) {
            Toast.makeText(this, "未检测到支持的背屏", Toast.LENGTH_LONG).show()
            return
        }
        if (pendingRear != null) return
        if (!Shizuku.pingBinder()) {
            RearDisplayBridge.offerShizuku(this, "请先在 Shizuku 启动服务，再回来打开背屏。")
            return
        }
        try {
            when {
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED -> launchRear(calibrate)
                Shizuku.shouldShowRequestPermissionRationale() ->
                    RearDisplayBridge.offerShizuku(this, "请在 Shizuku 的「已授权应用」中允许 Robot Eyes。")
                else -> {
                    pendingRear = calibrate
                    Shizuku.requestPermission(SHIZUKU_REQUEST)
                }
            }
        } catch (_: RuntimeException) {
            pendingRear = null
            RearDisplayBridge.offerShizuku(this, "Shizuku 已断开，请重新启动后重试。")
        }
    }

    private var switchingRear = false

    private fun launchRear(calibrate: Boolean) {
        if (switchingRear) return
        switchingRear = true
        RearDisplayBridge.launch(MainActivity.hasRearSurface()) { error ->
            if (error == null) {
                finishRearSwitch(calibrate, SystemClock.uptimeMillis() + 3000)
            } else {
                reportRearError(error)
            }
        }
    }

    private fun finishRearSwitch(calibrate: Boolean, deadline: Long) {
        if (isFinishing || isDestroyed) {
            switchingRear = false
            return
        }
        if (!MainActivity.hasRearSurface()) {
            if (SystemClock.uptimeMillis() >= deadline) {
                reportRearError("背屏页面未准备好，请解锁手机后重试")
            } else {
                window.decorView.postDelayed({ finishRearSwitch(calibrate, deadline) }, 100)
            }
            return
        }

        switchingRear = false
        if (calibrate) MainActivity.requestRearCalibration()
    }

    private fun reportRearError(error: String) {
        switchingRear = false
        EyesBus.log("Shizuku: $error")
        if (!isFinishing && !isDestroyed) {
            Toast.makeText(this, error, Toast.LENGTH_LONG).show()
        }
    }

    private companion object {
        const val SHIZUKU_REQUEST = 2
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingRear = savedInstanceState?.getString("pendingRear")?.toBooleanStrictOrNull()
        Shizuku.addRequestPermissionResultListener(rearPermission)
        if (savedInstanceState == null && Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("pendingRear", pendingRear?.toString())
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(rearPermission)
        super.onDestroy()
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        interaction = RobotInteractionBridge(this, engine.dartExecutor.binaryMessenger)
        engine.platformViewsController.registry.registerViewFactory("com.reareyes/eyes-preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, id: Int, args: Any?): PlatformView =
                    object : PlatformView {
                        private val eyes = EyesView(context)
                        override fun getView(): View = eyes
                        override fun dispose() = Unit
                    }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.reareyes/mobile")
            .setMethodCallHandler(::onCall)
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        interaction?.close()
        interaction = null
        super.cleanUpFlutterEngine(engine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        interaction?.onPermissionsResult(requestCode, grantResults)
    }

    override fun onStart() {
        super.onStart()
        RemoteConnection.screenStarted()
        startService(Intent(this, EyesService::class.java))
    }

    override fun onStop() {
        interaction?.suspendListening()
        RemoteConnection.screenStopped()
        super.onStop()
    }

    private fun pairingConfig(): String? = RemoteConnection.load(this)?.let {
        JSONObject().put("url", it.url).put("token", it.token).toString()
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> {
                val sources = EyesBus.connectedTransports().map { it.name }
                val feedback = RemoteConnection.feedback
                val usage = EyesBus.usage
                result.success(mapOf(
                    "state" to EyesBus.state.name, "connections" to sources,
                    "agents" to EyesBus.agentStates().mapValues { it.value.name },
                    "logs" to EyesBus.dumpLog(40),
                    "pairing" to pairingConfig(), "remoteState" to feedback.state?.name,
                    "five" to usage.fiveHour?.usedPercent, "fiveReset" to usage.fiveHour?.resetsAt,
                    "week" to usage.week?.usedPercent, "weekReset" to usage.week?.resetsAt,
                    "updatedAt" to feedback.updatedAt, "error" to feedback.error,
                    "syncTicket" to EyesBus.syncedTicket,
                    "rearSupported" to supportsRear(),
                ))
            }
            "loadPairing" -> result.success(pairingConfig())
            "savePairing" -> {
                val raw = call.arguments as? String
                try {
                    RemoteConnection.save(this, raw?.let(RemoteConnection::parse))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("pairing", "配对配置无效", null)
                }
            }
            "sync" -> result.success(EyesBus.requestSync())
            "preview" -> {
                val state = EyeState.entries.firstOrNull { it.name == call.arguments }
                if (state != null) EyesBus.preview(state) else EyesBus.greet()
                result.success(null)
            }
            "keepScreenOn" -> {
                val keepOn = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                window.setFlags(if (call.arguments == true) keepOn else 0, keepOn)
                result.success(null)
            }
            "rear" -> {
                requestRear(call.arguments == true)
                result.success(null)
            }
            "sleep" -> {
                val seconds = call.arguments as? Int
                if (seconds in SleepSettings.durations) SleepSettings.save(this, seconds!!)
                result.success(SleepSettings.load(this))
            }
            "lan" -> {
                (call.arguments as? Boolean)?.let { enabled ->
                    LanMcpSettings.setEnabled(this, enabled)
                    startService(Intent(this, EyesService::class.java))
                }
                val enabled = LanMcpSettings.enabled(this)
                val endpoints = if (enabled) LanMcpSettings.endpoints(this) else emptyList()
                result.success(mapOf("enabled" to enabled, "endpoints" to endpoints))
            }
            "copyLanConfig" -> {
                val endpoint = call.arguments as? String
                if (endpoint == null || !LanMcpSettings.enabled(this) ||
                    endpoint !in LanMcpSettings.endpoints(this)
                ) {
                    result.error("clipboard", "局域网地址已变化，请重新打开局域网 MCP。", null)
                    return
                }
                LanMcpSettings.copyConfig(this, endpoint)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
