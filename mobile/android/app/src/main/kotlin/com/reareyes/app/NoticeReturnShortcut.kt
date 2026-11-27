package com.reareyes.app

import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.ImageButton
import kotlin.math.roundToInt

internal class NoticeReturnShortcut(private val activity: FlutterHostActivity) {
    private val windows get() = activity.getSystemService(WindowManager::class.java)
    private var tab: ImageButton? = null

    fun show() {
        if (tab != null || !Settings.canDrawOverlays(activity)) return
        fun dp(value: Int) = (value * activity.resources.displayMetrics.density).roundToInt()
        val button = ImageButton(activity).apply {
            contentDescription = "返回 Robot Eyes 横屏"
            setImageResource(R.drawable.ic_eyes)
            setColorFilter(CyberColors.cyan)
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            setPadding(dp(10), dp(14), dp(8), dp(14))
            background = GradientDrawable().apply {
                setColor(CyberColors.surface)
                setStroke(dp(1), CyberColors.line)
                cornerRadii = floatArrayOf(
                    dp(9).toFloat(), dp(9).toFloat(), 0f, 0f,
                    0f, 0f, dp(9).toFloat(), dp(9).toFloat(),
                )
            }
            setOnClickListener {
                activity.startActivity(
                    Intent(activity, FlutterHostActivity::class.java)
                        .setAction(RETURN_TO_DESK)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP)
                )
                dismiss()
            }
        }
        val params = WindowManager.LayoutParams(
            dp(48), dp(52), WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.RIGHT or Gravity.CENTER_VERTICAL }
        runCatching { windows.addView(button, params) }.onSuccess { tab = button }
    }

    fun dismiss() {
        val button = tab ?: return
        tab = null
        runCatching { windows.removeViewImmediate(button) }
    }
}
