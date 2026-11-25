package com.reareyes.app

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable

/** Monochrome status symbols shared by the display badges and the status list. */
internal class StatusIcon(state: EyeState) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = CyberColors.forState(state)
        style = Paint.Style.STROKE
        strokeWidth = 1.7f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val shape = Path().apply {
        when (state) {
            EyeState.THINKING -> {
                moveTo(4f, 2.5f)
                lineTo(13f, 8f)
                lineTo(4f, 13.5f)
                close()
            }
            EyeState.QUESTION -> {
                moveTo(5f, 5.1f)
                cubicTo(5f, 1.8f, 11.4f, 1.4f, 11.4f, 5.2f)
                cubicTo(11.4f, 7.4f, 8f, 7.4f, 8f, 9.8f)
                addCircle(8f, 13f, 0.42f, Path.Direction.CW)
            }
            EyeState.DONE -> {
                moveTo(2.7f, 8.2f)
                lineTo(6.4f, 12f)
                lineTo(13.4f, 4.5f)
            }
            EyeState.ERROR -> {
                moveTo(8f, 3f)
                lineTo(8f, 9.4f)
                addCircle(8f, 13f, 0.42f, Path.Direction.CW)
            }
            EyeState.STOPPED -> addRoundRect(3f, 3f, 13f, 13f, 1f, 1f, Path.Direction.CW)
            EyeState.IDLE -> {
                moveTo(5.5f, 3.5f)
                lineTo(5.5f, 12.5f)
                moveTo(10.5f, 3.5f)
                lineTo(10.5f, 12.5f)
            }
            EyeState.SLEEP -> {
                moveTo(10.7f, 13.8f)
                cubicTo(3.2f, 15.4f, 0.1f, 5.6f, 7.3f, 2.1f)
                cubicTo(5.6f, 6.7f, 8.9f, 11.2f, 13.9f, 10.7f)
                cubicTo(13.1f, 12.2f, 12f, 13.2f, 10.7f, 13.8f)
                close()
            }
        }
    }

    override fun draw(canvas: Canvas) {
        val saved = canvas.save()
        canvas.translate(bounds.left.toFloat(), bounds.top.toFloat())
        canvas.scale(bounds.width() / 16f, bounds.height() / 16f)
        canvas.drawPath(shape, paint)
        canvas.restoreToCount(saved)
    }

    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
    @Suppress("DEPRECATION")
    override fun getOpacity() = PixelFormat.TRANSLUCENT
}
