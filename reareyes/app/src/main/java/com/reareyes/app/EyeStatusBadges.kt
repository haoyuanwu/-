package com.reareyes.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Shared status strip for the preview, rear display and landscape display. */
internal class EyeStatusBadges(private val context: Context) {
    data class Badge(val label: String, val state: EyeState?, val width: Float)
    data class Layout(
        val rows: List<List<Badge>>,
        val height: Float,
        val gap: Float,
        val named: Boolean,
        val description: String,
    ) {
        fun top(centerY: Float) = centerY - (rows.size - 1) * (height + gap) - height / 2f
    }

    private val background = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        color = CyberColors.text
    }
    private val priority = listOf(EyeState.QUESTION, EyeState.THINKING, EyeState.ERROR,
        EyeState.DONE, EyeState.STOPPED, EyeState.IDLE, EyeState.SLEEP)
    private val icons = EyeState.entries.associateWith(::StatusIcon)
    private var agents = emptyList<Map.Entry<String, EyeState>>()
    private var nextRefresh = 0L
    private var cached: Layout? = null
    private var lastWidth = 0f
    private var lastHeight = 0f
    private var lastState = EyeState.IDLE

    fun layout(state: EyeState, time: Long, w: Float, h: Float, desk: Boolean): Layout {
        if (time >= nextRefresh) {
            nextRefresh = time + 350L
            val current = EyesBus.agentStates().entries.sortedBy { priority.indexOf(it.value) }
            if (current != agents) {
                agents = current
                cached = null
            }
        }
        val previous = cached
        if (previous != null && lastWidth == w && lastHeight == h && lastState == state) return previous
        lastWidth = w
        lastHeight = h
        lastState = state
        val density = context.resources.displayMetrics.density
        val named = agents.isNotEmpty()
        val height = min(h * 0.085f, if (desk) 22f * density else 17f * density)
        val gap = height * 0.17f
        val available = if (desk) max(w - 128f * density, w * 0.6f) else w - 2f * gap
        val maxBadgeWidth = min(available, max(available * 0.46f, height * 7f))
        text.textSize = fontSize(height)
        fun badge(label: String, state: EyeState? = null): Badge {
            val width = (text.measureText(label) + chromeWidth(height, state != null, label.isNotEmpty()))
                .coerceAtMost(available)
            return Badge(label, state, width)
        }
        val rows = if (!named) {
            listOf(listOf(badge("", state)))
        } else {
            val nameWidth = max(0f, maxBadgeWidth - chromeWidth(height, hasIcon = true, hasLabel = true))
            val badges = agents.map { (name, state) ->
                badge(TextUtils.ellipsize(name, text, nameWidth, TextUtils.TruncateAt.END).toString(), state)
            }
            val packed = mutableListOf(mutableListOf<Badge>())
            var shown = 0
            for (item in badges) {
                val row = packed.last()
                if (row.isNotEmpty() && rowWidth(row, gap) + gap + item.width > available) {
                    if (packed.size == 2) break
                    packed.add(mutableListOf())
                }
                packed.last().add(item)
                shown++
            }
            if (shown < badges.size) {
                val row = packed.last()
                var more = badge("+${badges.size - shown}")
                while (row.isNotEmpty() && rowWidth(row, gap) + gap + more.width > available) {
                    row.removeAt(row.lastIndex)
                    shown--
                    more = badge("+${badges.size - shown}")
                }
                row.add(more)
            }
            packed
        }
        val description = if (named) agents.joinToString("，") { (name, value) -> "$name：${value.label}" }
        else state.label
        return Layout(rows, height, gap, named, description).also { cached = it }
    }

    fun draw(canvas: Canvas, layout: Layout, x: Float, width: Float, centerY: Float, desk: Boolean,
             time: Long, motionEnabled: Boolean) {
        val h = layout.height
        val radius = h / 2f
        val iconSize = (h * 0.70f).toInt().coerceAtLeast(1)
        val spacing = h * 0.12f
        text.textSize = fontSize(h)
        val startY = layout.top(centerY) + radius
        layout.rows.forEachIndexed { index, row ->
            val y = startY + index * (h + layout.gap)
            val rowWidth = rowWidth(row, layout.gap)
            var left = x + if (desk) 16f * context.resources.displayMetrics.density else (width - rowWidth) / 2f
            for (badge in row) {
                val right = left + badge.width
                val accent = badge.state?.let(CyberColors::forState) ?: CyberColors.muted
                background.style = Paint.Style.FILL
                background.color = CyberColors.background
                canvas.drawRoundRect(left, y - radius, right, y + radius, radius, radius, background)
                background.color = CyberColors.alpha(accent, 23)
                canvas.drawRoundRect(left, y - radius, right, y + radius, radius, radius, background)
                background.style = Paint.Style.STROKE
                background.strokeWidth = max(1f, h * 0.025f)
                background.color = CyberColors.alpha(accent, 175)
                canvas.drawRoundRect(left, y - radius, right, y + radius, radius, radius, background)

                val icon = icons[badge.state]
                val iconWidth = if (icon == null) 0f else iconSize.toFloat()
                val textOffset = iconWidth + if (icon != null && badge.label.isNotEmpty()) spacing else 0f
                val contentWidth = text.measureText(badge.label) + textOffset
                val contentLeft = left + (badge.width - contentWidth) / 2f
                if (icon != null) {
                    val top = (y - iconSize / 2f).toInt()
                    val start = contentLeft.toInt()
                    icon.setBounds(start, top, start + iconSize, top + iconSize)
                    icon.alpha = if (badge.state == EyeState.THINKING && motionEnabled)
                        (225 + 25 * sin(time / 275.0)).toInt() else 255
                    icon.draw(canvas)
                }
                canvas.drawText(badge.label, contentLeft + textOffset,
                    y - (text.ascent() + text.descent()) / 2f, text)
                left = right + layout.gap
            }
        }
    }

    private fun rowWidth(row: List<Badge>, gap: Float) =
        row.sumOf { it.width.toDouble() }.toFloat() + (row.size - 1) * gap

    private fun fontSize(height: Float): Float {
        val metrics = context.resources.displayMetrics
        val scaled = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, height * 0.63f / metrics.density, metrics)
        return scaled.coerceIn(height * 0.56f, height * 0.74f)
    }

    private fun chromeWidth(height: Float, hasIcon: Boolean, hasLabel: Boolean) =
        height * (0.44f + (if (hasIcon) 0.70f else 0f) + (if (hasIcon && hasLabel) 0.12f else 0f))
}
