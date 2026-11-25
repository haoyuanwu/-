package com.reareyes.app

import android.animation.ValueAnimator
import android.app.Activity
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout

/** 主屏支架模式，保持前台显示并复用完整的表情与手势。 */
class DeskActivity : Activity() {
    private lateinit var eyes: EyesView
    private lateinit var exit: Button
    private val controlsGesture by lazy {
        GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(event: MotionEvent): Boolean = true

            override fun onDoubleTap(event: MotionEvent): Boolean {
                val now = SystemClock.elapsedRealtime()
                val wasVisible = visibleUntil > now
                visibleUntil = if (wasVisible) 0L else now + CONTROLS_VISIBLE_MS
                if (wasVisible) {
                    exit.removeCallbacks(dimControls)
                    dimControls.run()
                } else {
                    refreshControls()
                }
                return true
            }
        })
    }
    private var visibleUntil = 0L
    private var fade: ValueAnimator? = null
    private val dimControls = Runnable {
        exit.isEnabled = false
        fade = ValueAnimator.ofFloat(exit.alpha, 0f).apply {
            duration = 220L
            addUpdateListener { setControlsOpacity(it.animatedValue as Float) }
            start()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        visibleUntil = savedInstanceState?.getLong("controlsVisibleUntil") ?: 0L
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false)

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 28) {
                val cutout = insets.displayCutout
                view.setPadding(cutout?.safeInsetLeft ?: 0, cutout?.safeInsetTop ?: 0,
                    cutout?.safeInsetRight ?: 0, cutout?.safeInsetBottom ?: 0)
            }
            insets
        }
        eyes = EyesView(this, EyesView.Presentation.DESK)
        root.addView(eyes, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        exit = Button(this).apply {
            text = "退出全屏"
            textSize = 13f
            isAllCaps = false
            setTextColor(CyberColors.muted)
            setPadding(dp(14), 0, dp(14), 0)
            background = RippleDrawable(ColorStateList.valueOf(CyberColors.alpha(CyberColors.cyan, 44)),
                GradientDrawable().apply {
                    setColor(CyberColors.surface)
                    setStroke(dp(1), CyberColors.line)
                    cornerRadius = dp(22).toFloat()
                }, null)
            setOnClickListener { finish() }
        }
        root.addView(exit, FrameLayout.LayoutParams(WRAP_CONTENT, dp(48), Gravity.END or Gravity.BOTTOM).apply {
            marginEnd = dp(16)
            bottomMargin = dp(16)
        })
        refreshControls()
        setContentView(root)
        hideSystemBars()
    }

    override fun onStart() {
        super.onStart()
        RemoteConnection.screenStarted()
    }

    override fun onStop() {
        RemoteConnection.screenStopped()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        refreshControls()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putLong("controlsVisibleUntil", visibleUntil)
    }

    override fun onDestroy() {
        exit.removeCallbacks(dimControls)
        fade?.cancel()
        super.onDestroy()
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        controlsGesture.onTouchEvent(event)
        return super.dispatchTouchEvent(event)
    }

    private fun refreshControls() {
        exit.removeCallbacks(dimControls)
        fade?.cancel()
        val remaining = visibleUntil - SystemClock.elapsedRealtime()
        exit.isEnabled = remaining > 0
        setControlsOpacity(if (remaining > 0) 1f else 0f)
        if (remaining > 0) exit.postDelayed(dimControls, remaining)
    }

    private fun setControlsOpacity(opacity: Float) {
        exit.alpha = opacity
        exit.visibility = if (opacity > 0f) View.VISIBLE else View.INVISIBLE
        eyes.deskUsageOpacity = opacity
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.apply {
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsets.Type.systemBars())
            }
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val CONTROLS_VISIBLE_MS = 15_000L
    }
}
