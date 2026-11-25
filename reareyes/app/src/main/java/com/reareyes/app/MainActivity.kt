package com.reareyes.app

import java.lang.ref.WeakReference
import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.method.ScrollingMovementMethod
import android.view.Display
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import rikka.shizuku.Shizuku

/**
 * 主屏提供控制和预览，在背屏上直接用全屏动画展示状态。
 */
class MainActivity : Activity() {

    companion object {
        private const val REAR_DISPLAY_ID = 1
        private const val SHIZUKU_REQUEST = 2
        private var calibrationDeadline = 0L
        private var rearSurface: WeakReference<EyesView>? = null

        internal fun hasRearSurface(): Boolean {
            val eyes = rearSurface?.get() ?: return false
            return eyes.isAttachedToWindow && eyes.display?.displayId == REAR_DISPLAY_ID &&
                eyes.isShown && eyes.width > 0 && eyes.height > 0
        }

        internal fun requestRearCalibration() {
            calibrationDeadline = SystemClock.uptimeMillis() + 3000
            EyesBus.onCalibrate?.invoke()
        }
    }

    private lateinit var syncButton: Button
    private lateinit var syncFeedback: TextView
    private val transportLabels = mutableMapOf<EyesBus.Transport, TextView>()
    private lateinit var agentStatusRows: LinearLayout
    private var displayedAgentStates: Map<String, EyeState>? = null
    private val transportRefresh = object : Runnable {
        override fun run() {
            if (!showingRear) {
                updateTransportLabels()
                updateAgentStatuses()
            }
            mainHandler.postDelayed(this, 1000)
        }
    }
    private fun updateTransportLabels() {
        val connected = EyesBus.connectedTransports()
        transportLabels.forEach { (source, label) ->
            val status = when (source) {
                connected.firstOrNull() -> "同步中"
                in connected -> "已连接"
                EyesBus.Transport.TAILSCALE ->
                    if (RemoteConnection.load(this) == null) "未配对" else "未连接"
                else -> "未连接"
            }
            label.text = "${source.label} · $status"
            label.setTextColor(if (source in connected) CyberColors.cyan else CyberColors.muted)
        }
    }

    private fun updateAgentStatuses() {
        if (!::agentStatusRows.isInitialized) return
        val states = EyesBus.agentStates()
        if (states == displayedAgentStates) return
        displayedAgentStates = states
        agentStatusRows.removeAllViews()
        fun addRow(label: String, state: EyeState?) {
            agentStatusRows.addView(text(label, 13f, color = if (state == null) CyberColors.muted else CyberColors.text).apply {
                setPadding(dp(12), dp(6), dp(12), dp(6))
                if (state != null) {
                    val icon = StatusIcon(state).apply { setBounds(0, 0, dp(14), dp(14)) }
                    compoundDrawablePadding = dp(8)
                    setCompoundDrawablesRelative(icon, null, null, null)
                }
            })
        }
        if (states.isEmpty()) addRow("暂无 AI 工具状态", null)
        states.forEach { (name, state) -> addRow("$name · ${state.label}", state) }
    }

    private var pendingSync: String? = null
    private val syncTimeout = Runnable {
        pendingSync = null
        if (!showingRear && ::syncButton.isInitialized) {
            syncButton.isEnabled = true
            syncFeedback.text = "同步超时，请检查电脑服务和连接设置。"
        }
    }
    private lateinit var logView: TextView
    private val mainHandler = Handler(Looper.getMainLooper())
    private val logListener: (String) -> Unit = { mainHandler.post { refreshLog() } }
    private val rearOnly by lazy { !launchesNativeHome() }
    private var showingRear = false
    private var enteredRear = false
    private var waitingForRear = false
    private val rearLaunchTimeout = Runnable {
        if (waitingForRear && !isOnRearDisplay()) finishAndRemoveTask()
    }
    private var rearRoot: FrameLayout? = null
    private var rearEyes: EyesView? = null
    private var calibrationPanel: ViewGroup? = null
    private val calibrationListener: () -> Unit = {
        mainHandler.post {
            if (rearRoot != null) {
                calibrationDeadline = 0
                openCalibration()
            }
        }
    }

    private var calibrateAfterPermission: Boolean? = null
    private val shizukuPermissionListener = Shizuku.OnRequestPermissionResultListener { requestCode, result ->
        if (requestCode == SHIZUKU_REQUEST) {
            val calibrate = calibrateAfterPermission
            calibrateAfterPermission = null
            if (calibrate != null) {
                if (result == PackageManager.PERMISSION_GRANTED) switchToRearDisplay(calibrate)
                else offerShizuku("请在 Shizuku 的「已授权应用」中允许 Robot Eyes。")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enteredRear = savedInstanceState?.getBoolean("enteredRear") ?: false
        stageRearLaunch(intent)
        calibrateAfterPermission = savedInstanceState?.getString("shizukuAction")?.toBooleanStrictOrNull()
        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)
        startService(Intent(this, EyesService::class.java))
        renderDisplay()
        handleRearAction(intent)
        if (!showingRear && launchesNativeHome() && Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        stageRearLaunch(intent)
        setIntent(intent)
        handleRearAction(intent)
    }

    private fun stageRearLaunch(intent: Intent) {
        if (enteredRear || isOnRearDisplay()) return
        if (!rearOnly && !intent.getBooleanExtra("com.reareyes.app.REAR_ONLY", false)) return
        waitingForRear = true
        mainHandler.removeCallbacks(rearLaunchTimeout)
        mainHandler.postDelayed(rearLaunchTimeout, 12000)
    }

    private fun handleRearAction(intent: Intent) {
        val action = intent.getStringExtra("com.reareyes.app.REAR_ACTION")
        if (action != "show" && action != "calibrate") return
        intent.removeExtra("com.reareyes.app.REAR_ACTION")
        window.decorView.post {
            if (isOnRearDisplay()) {
                if (action == "calibrate") openCalibration()
            } else {
                showOnRearDisplay(action == "calibrate")
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("enteredRear", enteredRear)
        outState.putString("shizukuAction", calibrateAfterPermission?.toString())
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(syncTimeout)
        mainHandler.removeCallbacks(rearLaunchTimeout)
        if (rearSurface?.get() === rearEyes) rearSurface = null
        Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener)
        super.onDestroy()
    }

    override fun onConfigurationChanged(config: android.content.res.Configuration) {
        super.onConfigurationChanged(config)
        renderDisplay()
    }

    override fun onStart() {
        super.onStart()
        RemoteConnection.screenStarted()
        if (!isFinishing) transportRefresh.run()
    }

    override fun onStop() {
        mainHandler.removeCallbacks(transportRefresh)
        RemoteConnection.screenStopped()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        if (isFinishing) return
        if (showingRear != isOnRearDisplay()) renderDisplay()
        if (waitingForRear) return
        if (isFinishing) return
        if (showingRear) {
            EyesBus.onCalibrate = calibrationListener
            openRequestedCalibration()
        }
        if (!showingRear) {
            EyesBus.onLog = logListener
            refreshLog()
        }
    }

    override fun onPause() {
        if (EyesBus.onLog === logListener) EyesBus.onLog = null
        if (EyesBus.onCalibrate === calibrationListener) EyesBus.onCalibrate = null
        super.onPause()
    }

    private fun launchesNativeHome() =
        packageManager.getLaunchIntentForPackage(packageName)?.component?.className == javaClass.name

    @Suppress("DEPRECATION")
    private fun isOnRearDisplay() = windowManager.defaultDisplay.displayId == REAR_DISPLAY_ID

    private fun openRequestedCalibration() {
        val root = rearRoot ?: return
        if (SystemClock.uptimeMillis() >= calibrationDeadline) return
        calibrationDeadline = 0
        root.post { if (rearRoot === root) openCalibration() }
    }

    private fun showOnRearDisplay(calibrate: Boolean) {
        val display = getSystemService(DisplayManager::class.java).getDisplay(REAR_DISPLAY_ID)
        if (Build.MODEL != "2509FPN0BC" || display == null) {
            Toast.makeText(this, "未检测到支持的背屏", Toast.LENGTH_LONG).show()
            return
        }

        if (!Shizuku.pingBinder()) {
            offerShizuku("先在 Shizuku 启动服务，再回来打开背屏。也可以用 Mac 的 eyes 命令。")
            return
        }

        try {
            when {
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED ->
                    switchToRearDisplay(calibrate)
                Shizuku.shouldShowRequestPermissionRationale() ->
                    offerShizuku("请在 Shizuku 的「已授权应用」中允许 Robot Eyes。")
                else -> {
                    calibrateAfterPermission = calibrate
                    Shizuku.requestPermission(SHIZUKU_REQUEST)
                }
            }
        } catch (_: RuntimeException) {
            calibrateAfterPermission = null
            offerShizuku("Shizuku 已断开，请重新启动后重试。")
        }
    }

    private fun switchToRearDisplay(calibrate: Boolean) {
        val app = applicationContext
        RearDisplayBridge.show(taskId) { error ->
            if (error != null) {
                EyesBus.log("Shizuku: $error")
                Toast.makeText(app, "背屏切换失败，请检查 Shizuku 后重试", Toast.LENGTH_LONG).show()
            } else if (calibrate) {
                requestRearCalibration()
            }
        }
    }

    private fun offerShizuku(message: String) = RearDisplayBridge.offerShizuku(this, message)

    private fun applyRearDisplayPower(onRearDisplay: Boolean) {
        val brightness = if (onRearDisplay) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
            else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        val attributes = window.attributes
        if (attributes.screenBrightness != brightness) {
            attributes.screenBrightness = brightness
            window.attributes = attributes
        }
        val keepOn = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        window.setFlags(if (onRearDisplay) keepOn else 0, keepOn)
        if (Build.VERSION.SDK_INT >= 27) setTurnScreenOn(onRearDisplay)
    }

    private fun renderDisplay() {
        if (isFinishing) return
        showingRear = isOnRearDisplay()
        applyRearDisplayPower(showingRear)
        if (!showingRear && rearOnly) {
            if (!waitingForRear || enteredRear) finishAndRemoveTask()
            return
        }
        if (showingRear) {
            enteredRear = true
            waitingForRear = false
            intent.removeExtra("com.reareyes.app.REAR_ONLY")
            mainHandler.removeCallbacks(rearLaunchTimeout)
        } else if (waitingForRear) {
            return
        }
        if (EyesBus.onCalibrate === calibrationListener) EyesBus.onCalibrate = null
        rearRoot = null
        if (rearSurface?.get() === rearEyes) rearSurface = null
        rearEyes = null
        calibrationPanel = null
        if (Build.VERSION.SDK_INT >= 30) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (showingRear)
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
            }
            window.setDecorFitsSystemWindows(!showingRear)
        }
        if (showingRear) {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or
                android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            val eyes = EyesView(this, EyesView.Presentation.REAR)
            val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
            if (rearOnly) {
                root.viewTreeObserver.addOnPreDrawListener {
                    // A move to display 0 can precede the Activity's configuration callback.
                    val onRear = root.display?.displayId == REAR_DISPLAY_ID
                    if (!onRear && root.isAttachedToWindow && !isFinishing) {
                        applyRearDisplayPower(false)
                        finishAndRemoveTask()
                    }
                    onRear
                }
            }
            root.addView(eyes, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
            ))
            rearRoot = root
            rearEyes = eyes
            rearSurface = WeakReference(eyes)
            EyesBus.onCalibrate = calibrationListener
            setContentView(root)
            openRequestedCalibration()
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = 0
            setContentView(buildUi())
            refreshLog()
        }
    }

    private fun openCalibration() {
        val root = rearRoot ?: return
        val eyes = rearEyes ?: return
        if (calibrationPanel != null) return
        val original = eyes.lensAlignment
        var draft = original
        var selected = 0
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = surface(CyberColors.alpha(CyberColors.surface, 248), CyberColors.line, 16)
            isClickable = true
        }
        panel.addView(text("镜头圆环校准", 16f, bold = true, color = Color.WHITE))
        val selectors = LinearLayout(this).also(panel::addView)
        val directions = LinearLayout(this).also(panel::addView)
        val radius = LinearLayout(this).also(panel::addView)
        val actions = LinearLayout(this).also(panel::addView)

        fun button(row: LinearLayout, label: String, action: () -> Unit): Button {
            return Button(this).apply {
                text = label
                textSize = 13f
                setAllCaps(false)
                minWidth = 0
                minimumWidth = 0
                setPadding(0, 0, 0, 0)
                styleButton(this, CyberColors.text)
                setOnClickListener { action() }
                row.addView(this, LinearLayout.LayoutParams(0, dp(46), 1f).apply {
                    setMargins(dp(2), dp(3), dp(2), dp(3))
                })
            }
        }

        val upper = button(selectors, "上镜头") { selected = 0 }
        val lower = button(selectors, "下镜头") { selected = 1 }

        fun refresh() {
            eyes.lensAlignment = draft
            eyes.calibrationLens = selected
            styleButton(upper, if (selected == 0) CyberColors.cyan else CyberColors.text, selected == 0)
            styleButton(lower, if (selected == 1) CyberColors.violet else CyberColors.text, selected == 1)
            upper.isSelected = selected == 0
            lower.isSelected = selected == 1
            eyes.invalidate()
        }

        upper.setOnClickListener { selected = 0; refresh() }
        lower.setOnClickListener { selected = 1; refresh() }

        fun adjust(dx: Int = 0, dy: Int = 0, dr: Int = 0) {
            draft = if (selected == 0) draft.copy(upper = draft.upper.adjusted(dx, dy, dr))
                else draft.copy(lower = draft.lower.adjusted(dx, dy, dr))
            refresh()
        }

        button(directions, "左移") { adjust(dx = -4) }
        button(directions, "右移") { adjust(dx = 4) }
        button(directions, "上移") { adjust(dy = -4) }
        button(directions, "下移") { adjust(dy = 4) }
        button(radius, "缩小") { adjust(dr = -4) }
        button(radius, "放大") { adjust(dr = 4) }
        button(actions, "恢复默认") { draft = LensAlignment.defaults; refresh() }

        fun close(save: Boolean) {
            if (save) draft.save(this)
            eyes.lensAlignment = if (save) draft else original
            eyes.calibrationLens = null
            root.removeView(panel)
            calibrationPanel = null
            eyes.invalidate()
        }

        button(actions, "取消") { close(false) }
        button(actions, "保存") { close(true) }
        calibrationPanel = panel
        val panelWidth = minOf(dp(276), root.width * 57 / 100).coerceAtLeast(dp(230))
        root.addView(panel, FrameLayout.LayoutParams(panelWidth, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.END or Gravity.CENTER_VERTICAL).apply { rightMargin = dp(10) })
        refresh()
    }

    // ---------- UI ----------

    private fun buildUi(): ScrollView {
        val root = ScrollView(this).apply {
            setBackgroundColor(CyberColors.background)
            clipToPadding = false
            isFillViewport = true
        }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(17), dp(20), dp(24))
        }
        root.addView(col, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val header = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        val icon = ImageView(this).apply {
            setImageResource(R.drawable.ic_eyes)
            imageTintList = ColorStateList.valueOf(CyberColors.cyan)
            background = surface(CyberColors.raised, CyberColors.alpha(CyberColors.cyan, 124), 13)
            importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        header.addView(icon, LinearLayout.LayoutParams(dp(52), dp(52)).apply { marginEnd = dp(12) })
        val title = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        title.addView(text("背屏电子眼", 26f, bold = true))
        title.addView(text("Agent 状态与表情", 13f, color = CyberColors.muted))
        header.addView(title)
        col.addView(header)
        col.addView(space(17))

        val deck = FrameLayout(this).apply {
            background = surface(0xFF000000.toInt(), CyberColors.alpha(CyberColors.cyan, 115), 19)
            clipToOutline = true
            setPadding(dp(1), dp(1), dp(1), dp(1))
            addView(EyesView(this@MainActivity), FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
            ))
        }
        col.addView(deck, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(192)))
        col.addView(space(16))

        col.addView(sectionTitle("显示控制"))
        col.addView(space(8))
        col.addView(control("主屏横屏显示", CyberColors.cyan, prominent = true) {
            startActivity(Intent(this, DeskActivity::class.java))
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        col.addView(space(8))
        val rearActions = LinearLayout(this)
        col.addView(rearActions)
        rearActions.addView(control("显示到背屏", CyberColors.cyan) {
            showOnRearDisplay(false)
        }, LinearLayout.LayoutParams(0, dp(46), 1f).apply { marginEnd = dp(8) })
        rearActions.addView(control("圆环校准", CyberColors.violet) { showOnRearDisplay(true) },
            LinearLayout.LayoutParams(0, dp(46), 1f))
        col.addView(space(6))
        col.addView(text("手机切屏需要 Shizuku。", 12f, color = CyberColors.muted))
        col.addView(space(10))
        syncButton = control("同步 Codex", CyberColors.cyan) {
            pendingSync = EyesBus.requestSync()
            syncButton.isEnabled = false
            syncFeedback.text = "正在同步…"
            mainHandler.postDelayed(syncTimeout, 10000)
        }.apply { isEnabled = pendingSync == null }
        col.addView(syncButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        col.addView(space(6))
        syncFeedback = text(
            if (pendingSync == null) "自动使用已连接的同步方式。" else "正在同步…",
            12f, color = CyberColors.muted
        ).apply { accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_POLITE }
        col.addView(syncFeedback)
        col.addView(space(8))
        col.addView(sectionTitle("连接状态"))
        transportLabels.clear()
        EyesBus.Transport.entries.forEach { source ->
            val label = text("", 13f, color = CyberColors.muted).apply {
                setPadding(dp(12), dp(6), dp(12), dp(6))
            }
            transportLabels[source] = label
            col.addView(label)
        }
        updateTransportLabels()
        col.addView(space(8))
        col.addView(control("局域网 MCP", CyberColors.cyan) { showLanMcpSettings() },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        col.addView(space(8))
        col.addView(control("远程连接", CyberColors.cyan) { showRemoteConnection() },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        col.addView(space(18))

        col.addView(sectionTitle("AI 工具状态"))
        agentStatusRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        displayedAgentStates = null
        col.addView(agentStatusRows)
        updateAgentStatuses()
        col.addView(space(18))

        col.addView(sectionTitle("自动睡眠"))
        col.addView(space(8))
        lateinit var sleepControl: Button
        sleepControl = control(sleepTimeoutLabel(), CyberColors.cyan) { showSleepSettings(sleepControl) }
        col.addView(sleepControl, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        col.addView(space(18))

        col.addView(sectionTitle("表情测试"))
        col.addView(space(8))
        for (states in listOf(
            listOf(EyeState.THINKING, EyeState.QUESTION, EyeState.DONE),
            listOf(EyeState.ERROR, EyeState.SLEEP, EyeState.IDLE)
        )) {
            val row = LinearLayout(this)
            states.forEachIndexed { index, state ->
                row.addView(control(state.label, CyberColors.forState(state)) { EyesBus.preview(state) },
                    LinearLayout.LayoutParams(0, dp(45), 1f).apply {
                        if (index < states.lastIndex) marginEnd = dp(8)
                    })
            }
            col.addView(row)
            col.addView(space(8))
        }
        col.addView(control("试试打招呼", CyberColors.violet) { EyesBus.greet() },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(45)))
        col.addView(space(19))

        col.addView(sectionTitle("运行日志"))
        col.addView(space(8))
        logView = text("", 11f, color = CyberColors.muted).apply {
            typeface = Typeface.MONOSPACE
            background = surface(CyberColors.surface, CyberColors.line, 12)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            setMovementMethod(ScrollingMovementMethod())
        }
        col.addView(logView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(150)))
        return root
    }

    private fun sleepTimeoutLabel() = "待机 ${SleepSettings.label(SleepSettings.load(this))}后睡眠"

    private fun showRemoteConnection() {
        val pairing = RemoteConnection.load(this)
        if (pairing == null) {
            showRemotePairing()
            return
        }
        val status = text("", 14f, color = CyberColors.muted)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(12), dp(24), dp(8))
            addView(text(pairing.url, 14f, color = CyberColors.cyan))
            addView(space(8))
            addView(status)
            addView(remoteHelpButton())
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("远程连接")
            .setView(content)
            .setPositiveButton("发消息") { _, _ -> showRemoteMessage(pairing) }
            .setNegativeButton("关闭", null)
            .setNeutralButton("管理配对") { _, _ -> showRemotePairing() }
            .create()
        val update = object : Runnable {
            override fun run() {
                val feedback = RemoteConnection.feedback
                val lastSync = feedback.updatedAt?.let {
                    android.text.format.DateFormat.getTimeFormat(this@MainActivity).format(java.util.Date(it))
                }
                status.text = listOfNotNull(
                    feedback.error ?: feedback.state?.let { "电脑状态 · ${it.label}" },
                    lastSync?.let { "上次同步 $it" }
                )
                    .joinToString("\n").ifEmpty { "正在等待电脑响应…" }
                mainHandler.postDelayed(this, 1000)
            }
        }
        dialog.setOnDismissListener { mainHandler.removeCallbacks(update) }
        dialog.show()
        update.run()
    }

    private fun showRemotePairing() {
        val input = EditText(this).apply {
            hint = "粘贴配对配置"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or
                android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine()
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("远程连接")
            .setMessage("粘贴从电脑 Robot Eyes 复制的完整配对配置。")
            .setView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(24), dp(8), dp(24), 0)
                addView(remoteHelpButton())
                addView(input, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            })
            .setPositiveButton("保存", null)
            .setNegativeButton("取消", null)
            .apply {
                if (RemoteConnection.load(this@MainActivity) != null) {
                    setNeutralButton("解除配对") { _, _ -> RemoteConnection.save(this@MainActivity, null) }
                }
            }
            .create()
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val pairing = try {
                RemoteConnection.parse(input.text.toString())
            } catch (_: Exception) {
                input.error = "请粘贴完整的配对配置。"
                return@setOnClickListener
            }
            RemoteConnection.save(this, pairing)
            dialog.dismiss()
            showRemoteConnection()
        }
    }

    private fun remoteHelpButton() = Button(this, null, android.R.attr.borderlessButtonStyle).apply {
        text = "连接教程"
        minHeight = dp(48)
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        setOnClickListener { showRemoteHelp() }
    }

    private fun showRemoteHelp() {
        AlertDialog.Builder(this)
            .setTitle("Tailscale 远程连接教程")
            .setMessage(
                """
                1. 在电脑和手机上打开 Tailscale，加入同一个 Tailscale 网络。在电脑上启动 Robot Eyes。

                2. 在电脑 Robot Eyes 的「Tailscale 连接」里点「重新检测」。如果没有检测到地址，点击「复制命令」，在电脑终端运行后再检测。

                3. 检测到地址后，点「复制配对配置」。把复制出来的整段 JSON 私下传到手机，里面包含 url 和 token。

                4. 回到手机「远程连接」，粘贴整段配置并点「保存」。如果已经配对，可在「管理配对」中更新配置。
                """.trimIndent()
            )
            .setPositiveButton("知道了", null)
            .show()
    }

    private fun showRemoteMessage(pairing: RemoteConnection.Pairing) {
        val input = EditText(this).apply {
            hint = "输入消息"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or
                android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 2
            maxLines = 5
            filters = arrayOf(android.text.InputFilter.LengthFilter(2000))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("发消息到电脑")
            .setView(remoteInput(input))
            .setPositiveButton("发送", null)
            .setNegativeButton("取消", null)
            .create()
        dialog.show()
        var previousText: String? = null
        var messageId = ""
        val send = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        send.setOnClickListener {
            val message = input.text.toString().trim()
            if (message.isEmpty()) {
                input.error = "请输入消息。"
                return@setOnClickListener
            }
            if (message != previousText) {
                messageId = java.util.UUID.randomUUID().toString()
                previousText = message
            }
            val id = messageId
            send.isEnabled = false
            input.isEnabled = false
            input.error = null
            send.text = "发送中…"
            Thread {
                val result = runCatching { RemoteConnection.send(pairing, id, message) }
                runOnUiThread {
                    if (!isFinishing && !isDestroyed && dialog.isShowing) {
                        result.onSuccess {
                            dialog.dismiss()
                            Toast.makeText(this, "已送达电脑", Toast.LENGTH_SHORT).show()
                        }.onFailure {
                            input.isEnabled = true
                            send.isEnabled = true
                            send.text = "重试"
                            input.error = RemoteConnection.describe(it as? Exception ?: Exception())
                        }
                    }
                }
            }.start()
        }
    }

    private fun remoteInput(input: EditText) = FrameLayout(this).apply {
        setPadding(dp(24), dp(8), dp(24), 0)
        addView(input, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private fun showLanMcpSettings() {
        val enabled = LanMcpSettings.enabled(this)
        val endpoints = LanMcpSettings.endpoints(this)
        val dialog = AlertDialog.Builder(this)
            .setTitle("局域网 MCP")
            .setMessage(when {
                !enabled -> "开启后，同一局域网内的桌面 Agent 可以通过 MCP 更新背屏表情。请在信任的网络上使用。"
                endpoints.isEmpty() -> "MCP 已开启。手机连上 Wi-Fi 或有线局域网后，重新打开这里获取地址。"
                else -> "Streamable HTTP\n${endpoints.joinToString("\n")}\n\n复制配置后，填入桌面工具的 MCP 设置。配置包含访问密钥。"
            })
            .setNeutralButton(if (enabled) "关闭 MCP" else "开启 MCP") { _, _ ->
                LanMcpSettings.setEnabled(this, !enabled)
                startService(Intent(this, EyesService::class.java))
                if (!enabled) showLanMcpSettings()
            }
            .setNegativeButton("返回", null)
        if (enabled && endpoints.isNotEmpty()) {
            dialog.setPositiveButton("复制配置") { _, _ ->
                if (endpoints.size == 1) copyLanMcpConfig(endpoints.single())
                else AlertDialog.Builder(this).setTitle("选择 MCP 地址")
                    .setItems(endpoints.toTypedArray()) { _, index -> copyLanMcpConfig(endpoints[index]) }
                    .setNegativeButton("返回", null).show()
            }
        }
        dialog.show()
    }

    private fun copyLanMcpConfig(endpoint: String) {
        LanMcpSettings.copyConfig(this, endpoint)
        Toast.makeText(this, "已复制 MCP 配置", Toast.LENGTH_SHORT).show()
    }

    private fun showSleepSettings(button: Button) {
        val durations = SleepSettings.durations
        AlertDialog.Builder(this)
            .setTitle("待机多久后睡眠")
            .setSingleChoiceItems(durations.map(SleepSettings::label).toTypedArray(),
                durations.indexOf(SleepSettings.load(this))) { dialog, selected ->
                SleepSettings.save(this, durations[selected])
                button.text = sleepTimeoutLabel()
                dialog.dismiss()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun sectionTitle(title: String): LinearLayout = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        val marker = android.view.View(this@MainActivity).apply { setBackgroundColor(CyberColors.cyan) }
        addView(marker, LinearLayout.LayoutParams(dp(3), dp(13)).apply { marginEnd = dp(8) })
        addView(text(title, 15f, bold = true).apply {
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        })
    }

    private fun surface(fill: Int, border: Int, radius: Int) = GradientDrawable().apply {
        setColor(fill)
        setStroke(dp(1), border)
        cornerRadius = dp(radius).toFloat()
    }

    private fun control(label: String, accent: Int, prominent: Boolean = false, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 14f
            setAllCaps(false)
            minWidth = 0
            minimumWidth = 0
            minimumHeight = 0
            setPadding(dp(4), 0, dp(4), 0)
            styleButton(this, accent, prominent)
            setOnClickListener { action() }
        }

    private fun styleButton(button: Button, accent: Int, prominent: Boolean = false) {
        val enabled = intArrayOf(android.R.attr.state_enabled)
        val disabled = intArrayOf(-android.R.attr.state_enabled)
        val fill = if (prominent) 0xFF153640.toInt() else CyberColors.surface
        val border = if (prominent) CyberColors.alpha(accent, 205) else CyberColors.line
        button.backgroundTintList = null
        button.stateListAnimator = null
        button.background = StateListDrawable().apply {
            addState(disabled, surface(CyberColors.background, CyberColors.line, 11))
            addState(enabled, RippleDrawable(ColorStateList.valueOf(CyberColors.alpha(accent, 48)),
                surface(fill, border, 11), null))
        }
        button.setTextColor(ColorStateList(arrayOf(disabled, enabled), intArrayOf(CyberColors.muted, accent)))
    }

    private fun refreshLog() {
        if (showingRear || !::logView.isInitialized) return
        val ticket = pendingSync
        if (ticket != null && ticket == EyesBus.syncedTicket) {
            pendingSync = null
            mainHandler.removeCallbacks(syncTimeout)
            syncButton.isEnabled = true
            val now = System.currentTimeMillis() / 1000L
            val five = EyesBus.usage.fiveHour?.remainingPercent(now)?.let { "$it%" } ?: "暂无"
            val week = EyesBus.usage.week?.remainingPercent(now)?.let { "$it%" } ?: "暂无"
            val source = EyesBus.connectedTransports().firstOrNull()?.label
            val prefix = if (source == null) "已同步" else "$source 已同步"
            syncFeedback.text = "$prefix · 5 小时剩余 $five · 周剩余 $week"
        }
        logView.text = EyesBus.dumpLog(40).joinToString("\n")
    }

    // ---------- 工具 ----------

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun space(v: Int) = TextView(this).apply {
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(v))
    }

    private fun text(s: String, size: Float, bold: Boolean = false, color: Int = CyberColors.text): TextView =
        TextView(this).apply {
            text = s
            textSize = size
            setTextColor(color)
            gravity = Gravity.START
            if (bold) paint.isFakeBoldText = true
        }
}
