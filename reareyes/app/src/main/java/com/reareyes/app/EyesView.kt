package com.reareyes.app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.RadialGradient
import android.graphics.Shader
import android.os.SystemClock
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** 双眼和眉毛共用一组几何参数，切换表情时在同一个轮廓上插值。 */
class EyesView(context: Context, private val display: Presentation = Presentation.PREVIEW) : View(context) {
    enum class Presentation { PREVIEW, REAR, DESK }

    private val fullScreen = display != Presentation.PREVIEW
    internal var keepAwake = false
        set(value) {
            if (field == value) return
            field = value
            sleepingPress = null
            sleepTap = null
            queuedWakeTap = null
            firstDeepSleepTap = null
            invalidate()
        }

    private fun sleepSession() =
        if (keepAwake || (display == Presentation.REAR &&
                EyesBus.rearConversationKeepsAwake(SystemClock.elapsedRealtime()))) null
        else EyesBus.sleepSession()

    internal var deskUsageOpacity = 1f
        set(value) {
            field = value
            invalidate()
        }
    private data class Point(val x: Float, val y: Float) {
        fun mix(to: Point, t: Float) = Point(blend(x, to.x, t), blend(y, to.y, t))
        fun shift(by: Point) = Point(x + by.x, y + by.y)
    }

    private data class ThinkingLook(
        val step: Int?,
        val startedAt: Long,
        val endsAt: Long,
        val moveDuration: Float,
        val fromEyes: Point,
        val fromPupils: Point,
        val destination: Point,
        val blinkAt: Long?
    )

    private data class ReadingStop(
        val direction: Point,
        val moveDuration: Float,
        val minHold: Long,
        val maxHold: Long,
        val blinkDelay: Long? = null
    )

    private data class Stroke(val start: Point, val control: Point, val end: Point, val width: Float) {
        fun shift(by: Point) = copy(start = start.shift(by), control = control.shift(by), end = end.shift(by))

        fun mix(to: Stroke, t: Float) = Stroke(
            start.mix(to.start, t), control.mix(to.control, t), end.mix(to.end, t),
            blend(width, to.width, t)
        )
    }

    private data class Eye(
        val center: Point, val halfWidth: Float, val halfHeight: Float,
        val bend: Float, val lowerInset: Float, val roundness: Float,
        val pupil: Float, val cross: Float, val brow: Stroke, val cheekLift: Float = 0f,
        val crescent: Float = 0f, val halfLid: Float = 0f
    ) {
        fun shift(by: Point) = copy(center = center.shift(by), brow = brow.shift(by))

        fun mix(to: Eye, t: Float) = Eye(
            center.mix(to.center, t), blend(halfWidth, to.halfWidth, t),
            blend(halfHeight, to.halfHeight, t), blend(bend, to.bend, t),
            blend(lowerInset, to.lowerInset, t), blend(roundness, to.roundness, t),
            blend(pupil, to.pupil, t), blend(cross, to.cross, t), brow.mix(to.brow, t),
            blend(cheekLift, to.cheekLift, t), blend(crescent, to.crescent, t),
            blend(halfLid, to.halfLid, t)
        )
    }

    private data class Face(val left: Eye, val right: Eye, val palette: Palette) {
        fun mix(to: Face, t: Float) = Face(left.mix(to.left, t), right.mix(to.right, t), palette.mix(to.palette, t))
    }

    private data class Palette(val top: Int, val middle: Int, val bottom: Int) {
        fun mix(to: Palette, t: Float) = Palette(
            mixColor(top, to.top, t), mixColor(middle, to.middle, t), mixColor(bottom, to.bottom, t)
        )
    }

    private data class TapParticle(
        val origin: Point,
        val startedAt: Long,
        val lifetime: Long,
        val drift: Point,
        val size: Float,
        val angle: Float,
        val spin: Float,
        val color: Int,
        val filled: Boolean,
    )

    private enum class Gesture {
        NORMAL, LOOK, TAP_LOOK, TRACK, PUZZLED, RELEASE, SLEEP_TOUCH
    }

    private data class SleepTap(
        val revision: Long,
        val startedAt: Long,
        val x: Float,
        val wakeAfterPeek: Boolean,
    )

    private enum class Expression { THINKING, QUESTION, DONE, ERROR, SLEEP, IDLE, FOCUS, HELLO, IDEA }

    private val palettes = mapOf(
        Expression.THINKING to palette(0xAFF7F5, 0x52DCE9, 0x3588EB),
        Expression.QUESTION to palette(0xFFE6A0, 0xFFC161, 0xFF7845),
        Expression.DONE to palette(0xCAFFE3, 0x70F2B8, 0x29B98C),
        Expression.ERROR to palette(0xFFCBC2, 0xFF8279, 0xE74263),
        Expression.SLEEP to palette(0xCBBFF3, 0xA092DF, 0x6358A3),
        Expression.IDLE to palette(0xE0EEFF, 0xA0C9F9, 0x668ED9),
        Expression.FOCUS to palette(0xDBF2FF, 0x8CCDFF, 0x608AF5),
        Expression.HELLO to palette(0xFFF3BE, 0xFFC89E, 0xE48FC6),
        Expression.IDEA to palette(0xFFFFCB, 0x81F5DE, 0x55BAFF)
    )

    private var displayedFace: Face? = null
    private var morphFrom: Face? = null
    private var morphStart = 0L
    private fun expressionFor(state: EyeState) =
        if (state == EyeState.STOPPED) Expression.IDLE else Expression.valueOf(state.name)

    private var target = expressionFor(EyesBus.state)
    private var motionEnabled = true
    private var voiceEnergy = 0f
    private val voicePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val mouthPath = Path()
    private var gesture = Gesture.NORMAL
    private var pointerId = MotionEvent.INVALID_POINTER_ID
    private var pressedAt = 0L
    private var stillSince = 0L
    private var puzzledUntil = 0L
    private var puzzledAtAnchor = false
    private var stillAnchor = Point(0f, 0f)
    private var touch = Point(0f, 0f)
    private var touchVelocity = Point(0f, 0f)
    private var touchEventAt = 0L
    private var touchMovedAt = 0L
    private var tapOrigin = touch
    private var tapMoved = false
    private val tapParticles = ArrayDeque<TapParticle>()
    private val particlePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val particlePath = Path()
    private val particleColors = intArrayOf(0xFF74F4FF.toInt(), 0xFFA392FF.toInt(), 0xFFF494EF.toInt())
    private var gaze = Point(0f, 0f)
    private var eyeSpacing = EYE_SPACING
    private var pupilGaze = Point(0f, 0f)
    private var idleExpression: Expression? = null
    private var idleExpressionUntil = 0L
    private var nextIdleExpressionAt = 0L
    private var idleGlance = Point(0f, 0f)
    private var nextGlanceAt = 0L
    private var glanceUntil = 0L
    private var lastStatus = EyesBus.state
    private var presentedDoneRevision = Long.MIN_VALUE
    private var donePresentedAt = 0L
    private var thinkingLook: ThinkingLook? = null
    private var lastFrameAt = 0L
    private var headTilt = 0f
    private var tapStartedAt: Long? = null
    private var tapWinks = false
    private var sleepingPress: EyesBus.SleepSession? = null
    private var interactivePress = false
    private var sleepTap: SleepTap? = null
    private var queuedWakeTap: SleepTap? = null
    private var firstDeepSleepTap: SleepTap? = null
    private var releasedAt = 0L
    private var held = false
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val holdDelay = ViewConfiguration.getLongPressTimeout().toLong()
    private var nextBlinkAt = 0L
    private var blinkStarted = 0L
    private var doubleBlink = false

    private val path = Path()
    private val outline = Path()
    private val curvedOutline = Path()
    private val outlineMeasure = PathMeasure()
    private val outlinePoint = FloatArray(2)
    private val matrix = Matrix()
    private var currentPalette: Palette? = null
    private var eyeFillShader: RadialGradient? = null
    private var strokeShader: LinearGradient? = null
    private val browPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val eyeHaloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val pupilPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val codePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = android.graphics.Typeface.MONOSPACE
    }
    private val codeBackdrop = RadialGradient(0f, 0f, 1f,
        intArrayOf(0xFF04150C.toInt(), 0xE6081D12.toInt(), 0x00081D12),
        floatArrayOf(0f, 0.62f, 1f), Shader.TileMode.CLAMP)
    private val glowStops = intArrayOf(
        4, 6, 8, 11, 14, 17, 20, 23, 26, 29, 34, 39, 44, 50, 57, 65, 76, 88
    )
    internal var lensAlignment = LensAlignment.load(context)
    internal var calibrationLens: Int? = null

    private val usagePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        strokeCap = Paint.Cap.ROUND
        typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
    }
    private val noticeBackground = Paint(Paint.ANTI_ALIAS_FLAG)
    private val noticeText = TextPaint(Paint.ANTI_ALIAS_FLAG)

    private val detailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val statusBadges = EyeStatusBadges(context)
    private var badgeDescription: String? = null

    init {
        setBackgroundColor(Color.BLACK)
        isClickable = true
        contentDescription = "电子眼。轻点让眼睛看过来，长按拖动让视线跟随手指"
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        tapParticles.clear()
        displayedFace = null
        morphFrom = null
        gesture = Gesture.NORMAL
        pointerId = MotionEvent.INVALID_POINTER_ID
        tapStartedAt = null
        interactivePress = false
        sleepingPress = null
        sleepTap = null
        queuedWakeTap = null
        firstDeepSleepTap = null
        releasedAt = 0L
        touchVelocity = Point(0f, 0f)
        gaze = Point(0f, 0f)
        eyeSpacing = EYE_SPACING
        pupilGaze = Point(0f, 0f)
        idleGlance = Point(0f, 0f)
        glanceUntil = 0L
        idleExpression = null
        idleExpressionUntil = 0L
        nextIdleExpressionAt = 0L
        lastStatus = EyesBus.state
        thinkingLook = null
        val now = SystemClock.elapsedRealtime()
        nextGlanceAt = now + 1900L
        lastFrameAt = 0L
        headTilt = 0f
        target = expressionFor(EyesBus.state)
        motionEnabled = ValueAnimator.areAnimatorsEnabled()
        scheduleBlink(now, blinkDelay(target == Expression.IDLE))
        postInvalidateOnAnimation()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val now = SystemClock.elapsedRealtime()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                pointerId = event.getPointerId(0)
                touch = Point(event.x, event.y)
                touchVelocity = Point(0f, 0f)
                touchEventAt = event.eventTime
                touchMovedAt = now
                stillAnchor = touch
                tapOrigin = touch
                tapMoved = false
                pressedAt = now
                stillSince = now
                puzzledUntil = 0L
                puzzledAtAnchor = false
                tapStartedAt = null
                sleepingPress = sleepSession()
                interactivePress = sleepingPress == null && allowsTouchReaction()
                releasedAt = 0L
                held = false
            }
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(pointerId)
                if (index >= 0) {
                    val next = Point(event.getX(index), event.getY(index))
                    val delta = (event.eventTime - touchEventAt).coerceAtLeast(1L)
                    val velocity = Point((next.x - touch.x) / delta, (next.y - touch.y) / delta)
                    touchVelocity = touchVelocity.mix(velocity, 1f - exp(-delta / 36f))
                    touch = next
                    touchEventAt = event.eventTime
                    touchMovedAt = now
                    if (!tapMoved) tapMoved = movedBeyondTapSlop()
                    val dx = touch.x - stillAnchor.x
                    val dy = touch.y - stillAnchor.y
                    if (dx * dx + dy * dy > touchSlop * touchSlop) {
                        stillAnchor = touch
                        stillSince = now
                        puzzledAtAnchor = false
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val index = event.actionIndex
                if (event.getPointerId(index) == pointerId) {
                    touch = Point(event.getX(index), event.getY(index))
                    pointerId = MotionEvent.INVALID_POINTER_ID
                    parent?.requestDisallowInterceptTouchEvent(false)
                    val sleep = sleepingPress
                    sleepingPress = null
                    if (sleep != null) {
                        if (EyesBus.isSleeping(sleep.revision) && !tapMoved && !movedBeyondTapSlop() &&
                            now - pressedAt < holdDelay
                        ) {
                            completeTap(now)
                        }
                    } else if (interactivePress &&
                        (held || tapMoved || movedBeyondTapSlop() || now - pressedAt >= holdDelay)
                    ) {
                        releasedAt = now
                    } else if (interactivePress) {
                        completeTap(now)
                    }
                    interactivePress = false
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                pointerId = MotionEvent.INVALID_POINTER_ID
                sleepingPress = null
                interactivePress = false
                parent?.requestDisallowInterceptTouchEvent(false)
            }
        }
        postInvalidateOnAnimation()
        return true
    }

    private fun completeTap(now: Long) {
        emitTapParticles(now)
        if (interactivePress) {
            super.performClick()
            startTapReaction(now)
        } else {
            performClick()
        }
    }

    private fun allowsTouchReaction() =
        EyesBus.state != EyeState.QUESTION && EyesBus.state != EyeState.ERROR

    private fun startTapReaction(time: Long) {
        tapStartedAt = time
        tapWinks = Random.nextInt(4) == 0
    }

    private fun movedBeyondTapSlop(): Boolean {
        val dx = touch.x - tapOrigin.x
        val dy = touch.y - tapOrigin.y
        return dx * dx + dy * dy > touchSlop * touchSlop
    }

    private fun emitTapParticles(time: Long) {
        if (!fullScreen || calibrationLens != null || !ValueAnimator.areAnimatorsEnabled()) return
        repeat(12) { index ->
            if (tapParticles.size >= 60) tapParticles.removeFirst()
            val spread = (index / 11f - 0.5f) * 0.30f
            tapParticles.addLast(TapParticle(
                origin = touch,
                startedAt = time,
                lifetime = Random.nextLong(460L, 820L),
                drift = Point(
                    height * (spread + Random.nextFloat() * 0.05f - 0.025f),
                    height * (0.07f + Random.nextFloat() * 0.16f),
                ),
                size = height * (0.009f + Random.nextFloat() * 0.012f),
                angle = Random.nextFloat() * 360f,
                spin = (Random.nextFloat() - 0.5f) * 200f,
                color = particleColors[index % particleColors.size],
                filled = index % 3 == 0,
            ))
        }
    }

    private fun drawTapParticles(canvas: Canvas, time: Long) {
        if (tapParticles.isEmpty()) return
        if (calibrationLens != null || !ValueAnimator.areAnimatorsEnabled()) {
            tapParticles.clear()
            return
        }
        tapParticles.removeAll { time - it.startedAt >= it.lifetime }
        for (particle in tapParticles) {
            val progress = (time - particle.startedAt).toFloat() / particle.lifetime
            val remaining = 1f - progress
            val travel = 1f - remaining * remaining
            val size = particle.size * (0.55f + 0.45f * remaining)
            val frame = canvas.save()
            canvas.translate(
                particle.origin.x + particle.drift.x * travel,
                particle.origin.y - particle.drift.y * travel,
            )
            canvas.rotate(particle.angle + particle.spin * progress)

            particlePath.rewind()
            particlePath.moveTo(0f, -size)
            particlePath.lineTo(size * 0.80f, size * 0.62f)
            particlePath.lineTo(-size * 0.80f, size * 0.62f)
            particlePath.close()
            particlePaint.color = particle.color
            particlePaint.style = Paint.Style.STROKE
            particlePaint.strokeWidth = size * 0.52f
            particlePaint.alpha = (84 * remaining).toInt()
            canvas.drawPath(particlePath, particlePaint)
            particlePaint.style = if (particle.filled) Paint.Style.FILL else Paint.Style.STROKE
            particlePaint.strokeWidth = size * 0.19f
            particlePaint.alpha = (235 * remaining).toInt()
            canvas.drawPath(particlePath, particlePaint)
            canvas.restoreToCount(frame)
        }
    }

    override fun performClick(): Boolean {
        super.performClick()
        if (!allowsTouchReaction()) return true
        val time = SystemClock.elapsedRealtime()
        val sleep = sleepSession()
        if (sleep == null) {
            startTapReaction(time)
        } else if (sleepTap?.let { it.revision == sleep.revision && it.wakeAfterPeek } != true &&
            queuedWakeTap?.revision != sleep.revision
        ) {
            tapStartedAt = null
            val first = firstDeepSleepTap?.takeIf {
                it.revision == sleep.revision && time - it.startedAt <= SECOND_TAP_WINDOW
            }
            val shouldWake = time - sleep.startedAt < DEEP_SLEEP_DELAY || first != null
            val peekEndsAt = first?.let { it.startedAt + SLEEP_PEEK_DURATION } ?: time
            val tap = SleepTap(sleep.revision, maxOf(time, peekEndsAt), touch.x, shouldWake)
            firstDeepSleepTap = tap.takeUnless { it.wakeAfterPeek }
            if (tap.startedAt > time && motionEnabled) {
                queuedWakeTap = tap
            } else {
                sleepTap = tap
            }
        }
        postInvalidateOnAnimation()
        return true
    }

    private fun gestureAt(time: Long): Gesture {
        queuedWakeTap?.let { tap ->
            if (!EyesBus.isSleeping(tap.revision)) {
                queuedWakeTap = null
            } else if (time >= tap.startedAt) {
                sleepTap = tap
                queuedWakeTap = null
            }
        }
        sleepTap?.let { tap ->
            if (EyesBus.isSleeping(tap.revision)) {
                if (tap.wakeAfterPeek) {
                    val duration = if (motionEnabled) SLEEP_PEEK_DURATION + SLEEP_WAKE_DURATION else 0L
                    if (time - tap.startedAt < duration) return Gesture.SLEEP_TOUCH
                    EyesBus.wakeFromSleep(tap.revision)
                } else if (motionEnabled && time - tap.startedAt < SLEEP_PEEK_DURATION) {
                    return Gesture.SLEEP_TOUCH
                }
            }
            sleepTap = null
        }
        if (pointerId != MotionEvent.INVALID_POINTER_ID && interactivePress) {
            if (!held && time - pressedAt >= holdDelay) {
                held = true
                stillSince = time
                stillAnchor = touch
            }
            if (!held) return if (tapMoved) Gesture.TRACK else Gesture.LOOK
            if (time < puzzledUntil) return Gesture.PUZZLED
            if (!puzzledAtAnchor && time - stillSince >= STILL_LOOK_DELAY) {
                puzzledAtAnchor = true
                puzzledUntil = time + PUZZLED_DURATION
                return Gesture.PUZZLED
            }
            return Gesture.TRACK
        }
        if (motionEnabled && releasedAt > 0 &&
            time - releasedAt < RELEASE_DURATION
        ) return Gesture.RELEASE
        val tap = tapStartedAt ?: return Gesture.NORMAL
        if (time - tap < TAP_DURATION) return Gesture.TAP_LOOK

        tapStartedAt = null
        return Gesture.NORMAL
    }

    private fun beginMorph(face: Expression, time: Long) {
        morphFrom = displayedFace
        target = face
        morphStart = time
    }

    override fun onDraw(canvas: Canvas) {
        val time = SystemClock.elapsedRealtime()
        val desk = display == Presentation.DESK
        val rear = display == Presentation.REAR
        val usage = if (desk || rear) EyesBus.connectedUsage else null
        val now = System.currentTimeMillis() / 1000L
        val five = usage?.fiveHour?.remainingPercent(now)
        val week = usage?.week?.remainingPercent(now)
        val h = if (desk) min(height.toFloat(), width / (REAR_FACE_ASPECT + 0.72f)) else height.toFloat()
        val faceTop = (height - h) / 2f
        val lensLane = if (rear && width >= h * 1.35f) {
            val cutout = rootWindowInsets?.displayCutout?.safeInsetLeft ?: 0
            if (cutout > 0) cutout.toFloat() else width * (296f / 976f)
        } else 0f
        val usageWidth = if (lensLane > 0f) {
            val sx = width.toFloat() / LensAlignment.WIDTH
            val scale = min(sx, h / LensAlignment.HEIGHT)
            val upper = lensAlignment.upper
            val lower = lensAlignment.lower
            val ringRight = max(upper.x * sx + upper.radius * scale, lower.x * sx + lower.radius * scale)
            max(lensLane, ringRight) + h * 0.045f
        } else 0f
        val faceAspect = if (desk || lensLane > 0f) REAR_FACE_ASPECT else FACE_ASPECT
        val w = min(width - usageWidth, h * faceAspect)
        val faceLeft = usageWidth + (width - usageWidth - w) / 2f
        if (w <= 0 || h <= 0) return

        val previousGesture = gesture
        gesture = gestureAt(time)
        val voice = EyesBus.rearVoice.takeIf { rear && gesture == Gesture.NORMAL }
        val listening = voice?.phase == EyesBus.VoicePhase.LISTENING
        val speechBeat = voice?.takeIf { it.phase == EyesBus.VoicePhase.SPEAKING }?.let {
            if (motionEnabled) {
                val seconds = (time - it.startedAt) / 1000f
                val beat = (seconds * 4.6f + 0.24f * sin(seconds * 7f)).mod(1f)
                val phrase = 0.5f - 0.5f * cos(seconds * 2f * PI.toFloat() / 1.65f)
                sin(beat * PI.toFloat()) * (0.48f + 0.52f * phrase)
            } else 0.35f
        }
        val status = EyesBus.state.let {
            if (it == EyeState.SLEEP &&
                (keepAwake || (rear && EyesBus.rearConversationKeepsAwake(time)))) EyeState.IDLE else it
        }
        if (status != lastStatus) {
            if (gesture == Gesture.NORMAL && blinkStarted == 0L &&
                (status == EyeState.IDLE || lastStatus == EyeState.IDLE)
            ) {
                scheduleBlink(time, blinkDelay(status == EyeState.IDLE))
            }
            lastStatus = status
        }
        val greetedAt = EyesBus.greetedAt
        val greeting = greetedAt > 0 && time - greetedAt < GREETING_DURATION &&
            (EyesBus.stateSince <= greetedAt || !fullScreen) &&
            (!fullScreen || (status != EyeState.QUESTION && status != EyeState.ERROR))
        val idleActive = voice == null && gesture == Gesture.NORMAL &&
            status == EyeState.IDLE && !greeting && motionEnabled
        val idleMood = idleExpressionAt(time, idleActive)
        val expression = when (gesture) {
            Gesture.NORMAL -> when {
                listening -> Expression.FOCUS
                voice?.phase == EyesBus.VoicePhase.THINKING -> Expression.THINKING
                voice != null -> Expression.HELLO
                greeting -> Expression.HELLO
                idleMood != null -> idleMood
                else -> expressionFor(status)
            }
            Gesture.PUZZLED -> Expression.QUESTION
            Gesture.TRACK, Gesture.RELEASE -> Expression.FOCUS
            Gesture.LOOK, Gesture.TAP_LOOK -> Expression.IDLE
            Gesture.SLEEP_TOUCH -> Expression.SLEEP
        }
        if (expression == Expression.DONE && status == EyeState.DONE &&
            presentedDoneRevision != EyesBus.stateSince
        ) {
            val doneRevision = EyesBus.stateSince
            val deferredByTouch = when (previousGesture) {
                Gesture.LOOK, Gesture.TRACK, Gesture.PUZZLED, Gesture.RELEASE, Gesture.TAP_LOOK -> true
                else -> false
            }
            donePresentedAt = if (deferredByTouch) time else doneRevision
            presentedDoneRevision = doneRevision
        }
        if (gesture != previousGesture) {
            if (gesture == Gesture.TRACK && previousGesture != Gesture.PUZZLED) {
                scheduleBlink(time, Random.nextLong(950L, 1300L))
            }
        }
        if (target != expression) {
            beginMorph(expression, time)
        }

        val lookingAtTouch = when (gesture) {
            Gesture.LOOK, Gesture.TAP_LOOK, Gesture.TRACK, Gesture.PUZZLED, Gesture.RELEASE -> true
            else -> false
        }
        val focused = expression == Expression.FOCUS
        val touchX = ((touch.x - faceLeft) / w - 0.5f).coerceIn(-0.65f, 0.65f)
        // 瞳光瞄在指尖稍上方，眼睛整体移动的幅度比瞳光小。
        val touchY = ((touch.y - faceTop - if (focused) h * 0.075f else 0f) / h - EYE_CENTER_Y)
            .coerceIn(-0.55f, 0.65f)
        val tapAge = tapStartedAt?.let { time - it } ?: 0L
        val attention = when (gesture) {
            Gesture.TAP_LOOK -> if (motionEnabled) 1f - smoothStep((tapAge - 330L) / 520f) else 1f
            Gesture.RELEASE -> {
                val phase = (time - releasedAt) / RELEASE_DURATION.toFloat()
                cos(phase * PI * 1.35).toFloat() * (1f - phase) * (1f - phase)
            }
            else -> 1f
        }
        val velocityAge = (time - touchMovedAt).coerceAtLeast(0L)
        val lead = if (motionEnabled && focused) 78f * exp(-velocityAge / 110f) else 0f
        val leadX = (touchVelocity.x * lead / w).coerceIn(-0.18f, 0.18f)
        val leadY = (touchVelocity.y * lead / h).coerceIn(-0.15f, 0.15f)
        val idleLook = if (idleActive) idleGlanceAt(time) else Point(0f, 0f)
        val thought = if (motionEnabled && expression == Expression.THINKING) {
            val current = thinkingLook
            if (current != null && time < current.endsAt) current else nextThinkingLook(time, current)
        } else null
        thinkingLook = thought
        val gazeTarget = if (lookingAtTouch) {
            val strength = if (focused || gesture == Gesture.PUZZLED) 0.90f else 0.68f
            Point((touchX * 0.36f).coerceIn(-0.159f, 0.159f) * strength * attention,
                (touchY * 0.40f).coerceIn(-0.080f, 0.19f) * strength * attention)
        } else Point(idleLook.x * 0.082f, idleLook.y * 0.063f)
        val pupilTarget = when {
            lookingAtTouch -> Point((touchX + leadX) * 1.58f * attention, (touchY + leadY) * 1.7f * attention)
            !motionEnabled -> Point(0f, 0f)
            idleActive -> idleLook
            expression == Expression.IDEA -> Point(0f, -0.18f)
            else -> Point(0f, 0f)
        }
        val elapsed = if (lastFrameAt == 0L) 16L else (time - lastFrameAt).coerceIn(1L, 50L)
        val heard = voice?.heardAt?.let {
            0.83f * (1f - smoothStep((time - it - 100L) / 360f))
        } ?: 0f
        val voiceTarget = if (listening) max(sqrt(voice?.level ?: 0f), heard) else 0f
        voiceEnergy = if (motionEnabled) {
            val response = if (voiceTarget > voiceEnergy) 44f else 150f
            blend(voiceEnergy, voiceTarget, 1f - exp(-elapsed / response))
        } else 0f
        lastFrameAt = time
        if (thought != null) {
            val age = time - thought.startedAt
            val direction = thought.destination
            gaze = thought.fromEyes.mix(Point(direction.x * 0.083f, direction.y * 0.067f),
                smoothStep((age - 20L) / (thought.moveDuration + 65f)))
            pupilGaze = thought.fromPupils.mix(direction, smoothStep(age / thought.moveDuration))
        } else if (motionEnabled) {
            val eyeSpeed = if (idleActive) 220.0 else if (lookingAtTouch) 105.0 else 76.0
            val pupilSpeed = if (lookingAtTouch) 38.0 else 155.0
            gaze = gaze.mix(gazeTarget, (1 - exp(-elapsed / eyeSpeed)).toFloat())
            pupilGaze = pupilGaze.mix(pupilTarget, (1 - exp(-elapsed / pupilSpeed)).toFloat())
        } else {
            gaze = gazeTarget
            pupilGaze = pupilTarget
        }
        val rearNotice = if (rear) EyesBus.rearNotice else null
        val noticeAge = rearNotice?.let { time - it.startedAt } ?: -1L
        val reacting = idleActive && expression == Expression.IDLE &&
            rearNotice?.react == true && noticeAge in 0L until 1_050L
        val noticeGlance = if (reacting) smoothStep(noticeAge / 180f) *
            (1f - smoothStep((noticeAge - 520L) / 480f)) else 0f
        val blink = when (gesture) {
            Gesture.TRACK -> if (motionEnabled) blink(time) else 1f
            Gesture.NORMAL -> when {
                thought != null -> thinkingBlink(time, thought)
                motionEnabled && (expression == Expression.IDLE || expression == Expression.QUESTION ||
                    listening || speechBeat != null) ->
                    blink(time, idle = expression == Expression.IDLE)
                else -> 1f
            }
            else -> 1f
        }
        val desiredSpacing = when (gesture) {
            Gesture.LOOK, Gesture.TAP_LOOK, Gesture.TRACK, Gesture.PUZZLED, Gesture.RELEASE ->
                blend(EYE_SPACING, interactionEyeSpacing(faceLeft + w * 0.5f,
                    faceTop + h * EYE_CENTER_Y, lensLane), attention.coerceAtLeast(0f))
            else -> EYE_SPACING
        }
        eyeSpacing = if (motionEnabled) blend(eyeSpacing, desiredSpacing, (1 - exp(-elapsed / 100.0)).toFloat())
            else desiredSpacing
        val alertBlink = if (reacting) 1f - 0.88f * pulse(noticeAge - 320L, 210L) else 1f
        var destination = faceFor(expression, time, blink * alertBlink, w / h, eyeSpacing,
            listeningEnergy = voiceEnergy.takeIf { listening }, speechBeat = speechBeat)
        if (gesture == Gesture.TAP_LOOK && motionEnabled) {
            val near = smoothStep((abs(touchX) - 0.08f) / 0.37f)
            val wink = if (tapWinks) 0.54f * pulse(tapAge - 420L, 260L) else 0f
            val squint = max(near * 0.28f * pulse(tapAge, 530L), wink)
            val eye = if (touchX < 0f) destination.left else destination.right
            val narrowed = eye.copy(halfHeight = eye.halfHeight * (1f - squint),
                pupil = eye.pupil * (1f - squint))
            destination = if (touchX < 0f) destination.copy(left = narrowed) else destination.copy(right = narrowed)
        }
        val morphDuration = if (expression == Expression.DONE || lookingAtTouch) 145f else 275f
        val progress = if (motionEnabled) ((time - morphStart) / morphDuration).coerceIn(0f, 1f) else 1f
        val origin = morphFrom
        val tap = sleepTap
        val face = if (gesture == Gesture.SLEEP_TOUCH && tap != null) {
            val age = time - tap.startedAt
            val awake = faceFor(Expression.IDLE, time, 1f, w / h)
            if (age >= SLEEP_PEEK_DURATION) {
                val opening = (age - SLEEP_PEEK_DURATION).toFloat() / SLEEP_WAKE_DURATION
                destination.mix(awake, opening * opening * (3f - 2f * opening))
            } else if (age >= SLEEP_PEEK_CLOSED_AT) {
                destination
            } else {
                if (tap.x <= faceLeft + w / 2f) {
                    destination.copy(left = sleepPeekEye(destination.left, awake.left, age))
                } else {
                    destination.copy(right = sleepPeekEye(destination.right, awake.right, age))
                }
            }
        } else if (origin != null && progress < 1f) {
            // 新动作从上一帧的轮廓接着走，快速切换也不会跳回初始表情。
            origin.mix(destination, progress * progress * (3f - 2f * progress))
        } else {
            morphFrom = null
            destination
        }
        displayedFace = face

        if (lensLane > 0f && (five != null || week != null || calibrationLens != null)) {
            drawUsage(canvas, h, five, week)
        }
        if (desk && (five != null || week != null)) drawDeskUsage(canvas, h, five, week)
        val frame = canvas.save()
        canvas.translate(faceLeft, faceTop)
        val pose = canvas.save()
        val touchTilt = if (motionEnabled && lookingAtTouch) {
            touchX * 8f * attention + leadX * 14f * attention
        } else 0f
        val expressionAge = time - if (status == EyeState.DONE) donePresentedAt else morphStart
        val voiceTilt = if (motionEnabled && voice != null && (listening || speechBeat != null)) {
            sin((time - voice.startedAt) / 300f) * (voiceEnergy * 3.5f + (speechBeat ?: 0f) * 3f)
        } else 0f
        val nextTilt = headAngle(expression, expressionAge) + touchTilt + voiceTilt
        headTilt = blend(headTilt, nextTilt, (1 - exp(-elapsed / 54.0)).toFloat())
        canvas.rotate(headTilt, w * 0.5f, h * 0.46f)
        if (rear) canvas.scale(1.07f, 1.07f, w * 0.5f, h * EYE_CENTER_Y)
        canvas.translate(w * 0.037f * noticeGlance, -h * 0.037f * noticeGlance)
        val eyePalette = if (noticeGlance > 0f) {
            face.palette.mix(palettes.getValue(Expression.THINKING), noticeGlance * 0.72f)
        } else face.palette
        updateEyeShaders(eyePalette)
        val codeAge = if (thought != null && thought.step == null) {
            (time - thought.startedAt - THINK_CODE_SETTLE).takeIf { it >= 0L }
        } else null
        drawEye(canvas, face.left.shift(gaze), w, h, pupilGaze, codeAge, innerAtEnd = true)
        drawEye(canvas, face.right.shift(gaze), w, h, pupilGaze, codeAge, innerAtEnd = false)
        if (listening) drawListeningBars(canvas, time, w, h, progress)
        if (speechBeat != null) drawSpeakingMouth(canvas, w, h, speechBeat, progress)
        canvas.restoreToCount(pose)
        drawDetails(canvas, expression, status, face.palette, time, w, h, progress)
        canvas.restoreToCount(frame)
        val badgeLeft = if (rear) usageWidth else 0f
        val badgeWidth = width - badgeLeft
        val badges = statusBadges.layout(status, time, badgeWidth, h, desk, showLocalLoading = rear)
        val description = badges?.description
        if (badgeDescription != description) {
            badgeDescription = description
            val statusDescription = description?.let { "$it。" }.orEmpty()
            contentDescription = "电子眼。${statusDescription}轻点让眼睛看过来，长按拖动让视线跟随手指"
        }
        if (badges != null) {
            val density = resources.displayMetrics.density
            val badgeY = when {
                rear -> height - max(2f * density, h * 0.025f) - badges.height / 2f
                desk -> height - 40f * density
                else -> faceTop + h * 0.9f
            }
            statusBadges.draw(canvas, badges, badgeLeft, badgeWidth, badgeY, desk, time, motionEnabled)
        }
        drawTapParticles(canvas, time)
        if (rearNotice != null) drawRearNotice(canvas, usageWidth, rearNotice, noticeAge)
        postInvalidateOnAnimation()
    }

    private fun drawListeningBars(canvas: Canvas, time: Long, w: Float, h: Float, progress: Float) {
        voicePaint.color = 0xFF8CCDFF.toInt()
        voicePaint.alpha = (progress * (150 + 105 * voiceEnergy)).toInt()
        for (index in -2..2) {
            val motion = 0.5f + 0.5f * sin(time / 75f + index * 1.55f)
            val barHeight = h * (0.013f + voiceEnergy * (0.025f + 0.058f * motion) *
                (1f - 0.17f * abs(index)))
            val x = w * 0.5f + h * index * 0.041f
            val y = h * 0.745f
            val radius = h * 0.008f
            canvas.drawRoundRect(x - radius, y - barHeight / 2f, x + radius, y + barHeight / 2f,
                radius, radius, voicePaint)
        }
    }

    private fun drawSpeakingMouth(canvas: Canvas, w: Float, h: Float, beat: Float, progress: Float) {
        val x = w * 0.5f
        val y = h * 0.742f
        val width = h * (0.123f - 0.047f * beat)
        val opening = h * (0.028f + 0.112f * beat) * progress
        mouthPath.rewind()
        mouthPath.moveTo(x - width, y)
        mouthPath.quadTo(x, y + h * 0.013f, x + width, y)
        mouthPath.cubicTo(x + width * 0.67f, y + opening,
            x - width * 0.67f, y + opening, x - width, y)
        mouthPath.close()
        voicePaint.color = 0xFFFFC89E.toInt()
        voicePaint.alpha = (progress * 240f).toInt()
        canvas.drawPath(mouthPath, voicePaint)
    }

    private fun drawRearNotice(canvas: Canvas, leftInset: Float, notice: EyesBus.RearNotice, age: Long) {
        if (age !in 0L until 9_000L) return
        val density = resources.displayMetrics.density
        val margin = 8f * density
        val available = width - leftInset - margin * 2f
        if (available < 54f * density) return
        val signalWidth = min(available, 178f * density)
        val left = width - margin - signalWidth
        val right = left + signalWidth
        val entry = if (motionEnabled) smoothStep(age / 320f) else 1f
        val exit = if (motionEnabled) smoothStep((9_000L - age) / 220f) else 1f
        val opacity = entry * exit
        val top = margin - (1f - entry) * 5f * density
        val bottom = top + (if (notice.text.isBlank()) 34f else 46f) * density
        val corner = 7f * density

        noticeBackground.style = Paint.Style.FILL
        noticeBackground.color = CyberColors.alpha(CyberColors.background, (245 * opacity).toInt())
        canvas.drawRoundRect(left, top, right, bottom, corner, corner, noticeBackground)
        noticeBackground.strokeWidth = density
        noticeBackground.color = CyberColors.alpha(CyberColors.cyan, (170 * opacity).toInt())
        canvas.drawLine(left + corner, top, left + corner + 20f * density, top, noticeBackground)
        canvas.drawLine(right - corner - 20f * density, bottom, right - corner, bottom, noticeBackground)
        if (motionEnabled && age < 400L) {
            val t = age / 400f
            val x = blend(left + corner, right - corner, t)
            noticeBackground.color = CyberColors.alpha(CyberColors.cyan, (100 * pulse(age, 400L)).toInt())
            canvas.drawLine(x, top + 2f * density, x, bottom - 2f * density, noticeBackground)
        }

        val icon = notice.icon
        val iconSize = (20f * density).toInt()
        val showIcon = icon != null && signalWidth >= 92f * density
        if (icon != null && showIcon) {
            val x = (left + 7f * density).toInt()
            val y = ((top + bottom - iconSize) / 2f).toInt()
            icon.setBounds(x, y, x + iconSize, y + iconSize)
            icon.alpha = (255 * opacity).toInt()
            icon.draw(canvas)
        }
        val labelX = left + (if (showIcon) 33f else 7f) * density
        fun line(value: String, centerY: Float, size: Float, color: Int) {
            noticeText.textAlign = Paint.Align.LEFT
            noticeText.textSize = size * density
            noticeText.color = CyberColors.alpha(color, (255 * opacity).toInt())
            val text = TextUtils.ellipsize(value, noticeText, right - labelX - 6f * density, TextUtils.TruncateAt.END)
            canvas.drawText(text.toString(), labelX,
                centerY - (noticeText.ascent() + noticeText.descent()) / 2f, noticeText)
        }

        line(notice.source, top + 9f * density, 9f, CyberColors.cyan)
        line(notice.title, top + 22f * density, 11f, CyberColors.text)
        if (notice.text.isNotBlank()) line(notice.text, top + 35f * density, 10f, CyberColors.text)
    }

    private fun drawUsage(canvas: Canvas, h: Float, five: Int?, week: Int?) {
        val sx = width.toFloat() / LensAlignment.WIDTH
        val sy = h / LensAlignment.HEIGHT
        val scale = min(sx, sy)
        fun ring(index: Int, geometry: LensRing, label: String, percent: Int?, accent: Int) {
            val x = geometry.x * sx
            val y = geometry.y * sy
            val radius = geometry.radius * scale
            val editing = calibrationLens
            if (editing == null && percent == null) return
            val displayPercent = if (editing != null) 100 else percent
            usagePaint.style = Paint.Style.STROKE
            usagePaint.strokeWidth = radius * 0.137f
            usagePaint.color = 0xFF324450.toInt()
            canvas.drawCircle(x, y, radius, usagePaint)
            if (displayPercent != null && displayPercent > 0) {
                usagePaint.color = accent
                if (editing != null && editing != index) usagePaint.alpha = 82
                canvas.drawArc(x - radius, y - radius, x + radius, y + radius,
                    -90f, displayPercent * 3.6f, false, usagePaint)
            }
            if (editing != null || percent == null) return

            // 文字沿每个圆环的右下弧摆放，并随镜头校准移动。
            usagePaint.style = Paint.Style.FILL
            usagePaint.textAlign = Paint.Align.LEFT
            usagePaint.textSize = h * 0.041f
            usagePaint.color = 0xF4EDF7FF.toInt()
            val labelX = x + radius * 0.83f + h * 0.010f
            val valueY = (y + radius * 0.91f).coerceAtMost(h * 0.95f)
            canvas.drawText("$percent%", labelX, valueY, usagePaint)
            usagePaint.textSize = h * 0.027f
            usagePaint.color = 0xBBD3E6F7.toInt()
            canvas.drawText(label, labelX, valueY + h * 0.038f, usagePaint)
        }
        ring(0, lensAlignment.upper, "5 小时剩余", five, 0xFF70DFF1.toInt())
        ring(1, lensAlignment.lower, "周剩余", week, 0xFF9EACFF.toInt())
    }

    private fun drawDeskUsage(canvas: Canvas, h: Float, five: Int?, week: Int?) {
        val density = resources.displayMetrics.density
        val radius = min(18f * density, h * 0.054f)
        val y = 16f * density + radius
        val alpha = (deskUsageOpacity * 255).toInt()

        fun ring(x: Float, label: String, percent: Int, accent: Int) {
            usagePaint.style = Paint.Style.STROKE
            usagePaint.strokeWidth = radius * 0.075f
            usagePaint.color = CyberColors.alpha(CyberColors.line, alpha)
            canvas.drawCircle(x, y, radius, usagePaint)
            if (percent > 0) {
                usagePaint.color = CyberColors.alpha(accent, alpha)
                canvas.drawArc(x - radius, y - radius, x + radius, y + radius,
                    -90f, percent * 3.6f, false, usagePaint)
            }
            usagePaint.style = Paint.Style.FILL
            usagePaint.textAlign = Paint.Align.CENTER
            usagePaint.textSize = radius * 0.59f
            usagePaint.color = CyberColors.alpha(CyberColors.text, alpha)
            val baseline = y - (usagePaint.ascent() + usagePaint.descent()) / 2f
            canvas.drawText("$percent%", x, baseline, usagePaint)
            usagePaint.textSize = min(11f * resources.displayMetrics.scaledDensity, radius * 0.63f)
            usagePaint.color = CyberColors.alpha(CyberColors.muted, alpha)
            canvas.drawText(label, x, y + radius + usagePaint.textSize * 1.55f, usagePaint)
        }
        val x = 16f * density + radius
        if (five != null) ring(x, "5 小时", five, CyberColors.cyan)
        if (week != null) {
            val weekX = if (five == null) x else x + radius * 2f + 12f * density
            ring(weekX, "本周", week, CyberColors.violet)
        }
    }

    private fun idleExpressionAt(time: Long, active: Boolean): Expression? {
        if (!active) {
            if (nextIdleExpressionAt != 0L) {
                idleExpression = null
                idleExpressionUntil = 0L
                nextIdleExpressionAt = 0L
                glanceUntil = 0L
                nextGlanceAt = time + 1900L
            }
            return null
        }
        if (nextIdleExpressionAt == 0L) nextIdleExpressionAt = time + Random.nextLong(10_000L, 16_000L)
        if (time >= nextIdleExpressionAt) {
            idleExpression = IDLE_REACTIONS.random()
            idleExpressionUntil = time + Random.nextLong(1150L, 1550L)
            nextIdleExpressionAt = idleExpressionUntil + Random.nextLong(13_000L, 23_000L)
        }
        return idleExpression.takeIf { time < idleExpressionUntil }
    }

    private fun idleGlanceAt(time: Long): Point {
        if (time >= nextGlanceAt) {
            val side = if (Random.nextBoolean()) 1f else -1f
            idleGlance = when (Random.nextInt(4)) {
                0 -> Point(side * 0.84f, 0.04f)
                1 -> Point(side * 0.56f, -0.71f)
                2 -> Point(side * 0.60f, 0.55f)
                else -> Point(0.08f * side, -0.74f)
            }
            glanceUntil = time + Random.nextLong(660L, 1340L)
            nextGlanceAt = glanceUntil + Random.nextLong(2200L, 4300L)
        }
        return if (time < glanceUntil) idleGlance else Point(0f, 0f)
    }

    private fun headAngle(expression: Expression, age: Long): Float {
        if (!motionEnabled) return 0f
        return when (expression) {
            Expression.DONE -> {
                val sway = age - 190L
                if (sway in 0L..620L) {
                    sin(sway / 620.0 * 2 * PI).toFloat() * 5.3f * pulse(sway, 620L)
                } else 0f
            }
            Expression.SLEEP -> {
                val turn = age % 15_800L - 11_000L
                val side = if ((age / 15_800L) % 2 == 0L) -1f else 1f
                side * 8.5f * pulse(turn, 3800L)
            }
            else -> 0f
        }
    }

    private fun smallEyeOnRight(): Float {
        if (gesture != Gesture.PUZZLED) return 1f
        val amount = ((pupilGaze.x + 0.44f) / 0.88f).coerceIn(0f, 1f)
        return amount * amount * (3f - 2f * amount)
    }

    private fun interactionEyeSpacing(centerX: Float, centerY: Float, leftEdge: Float): Float {
        val dx = touch.x - centerX
        val dy = touch.y - centerY
        val horizontal = if (dx < 0f) centerX - leftEdge else width - centerX
        val vertical = if (dy < 0f) centerY else height - centerY
        // Along any ray from the eye center this is 0 at the center and 1 at the first screen edge.
        val distance = max(abs(dx) / max(1f, horizontal), abs(dy) / max(1f, vertical)).coerceIn(0f, 1f)
        return blend(NARROW_EYE_SPACING, EYE_SPACING, distance)
    }

    private fun faceFor(expression: Expression, time: Long, blink: Float, canvasAspect: Float,
                        eyeSpacing: Float = EYE_SPACING, listeningEnergy: Float? = null,
                        speechBeat: Float? = null): Face {
        val age = time - morphStart
        val swell = if (motionEnabled) pulse(age, 760L) else 0f
        fun openEye(x: Float, y: Float, diameter: Float, height: Float, blink: Float, browY: Float,
                            tilt: Float, arch: Float, showBrow: Boolean = true, lowerInset: Float = 0f,
                            cheekLift: Float = 0f): Eye {
            val visible = ((blink - 0.18f) / 0.82f).coerceIn(0f, 1f)
            // 用完整睁眼高度限制实际像素宽度。闭眼只压缩高度，不缩窄横向轮廓。
            val halfWidth = min(diameter * 0.46f, height * 0.37f / canvasAspect)
            return Eye(
                Point(x, y), halfWidth, blend(0.014f, height / 2f, visible),
                0f, lowerInset * visible, 1f,
                visible, 0f, brow(x, browY, tilt, arch, if (showBrow) 0.024f else 0f),
                cheekLift * visible
            )
        }

        fun eye(side: Int): Eye {
            val left = side < 0
            val x = 0.5f + side * eyeSpacing
            val y = EYE_CENTER_Y
            return when (expression) {
                Expression.THINKING -> openEye(x, y, 0.30f, 0.405f, blink,
                    0.175f, 0f, 0f, showBrow = false,
                    lowerInset = (pupilGaze.y * 2f).coerceIn(0f, 1f) * 0.022f)
                Expression.IDLE -> openEye(x, y, 0.275f, 0.432f, blink,
                    0.145f, 0f, 0f, showBrow = false)
                Expression.IDEA -> openEye(x, y - 0.023f, 0.327f,
                    0.515f + swell * 0.039f, 1f, 0.15f, 0f, 0f, showBrow = false)
                Expression.QUESTION -> {
                    val smallRight = smallEyeOnRight()
                    val smallHere = if (left) 1f - smallRight else smallRight
                    val tilt = side * 0.035f
                    val large = openEye(x, y - 0.055f, 0.285f, 0.485f, blink,
                        0.085f, tilt, 0.07f)
                    val small = openEye(x, y + 0.065f, 0.25f, 0.28f, blink,
                        0.245f, tilt, 0.042f, lowerInset = 0.019f, cheekLift = side * 0.025f)
                    large.mix(small, smallHere)
                }
                Expression.DONE -> {
                    val crescent = Eye(
                        Point(x, y + 0.07f - swell * 0.037f),
                        0.148f + swell * 0.007f, 0.051f, 0.286f + swell * 0.028f, 0f, 1f, 0f, 0f,
                        brow(x, 0.153f, 0f, 0.092f, 0f), crescent = 1f
                    )
                    val doneAge = time - donePresentedAt
                    val pop = if (motionEnabled && EyesBus.state == EyeState.DONE) smoothStep(doneAge / 105f) *
                        (1f - smoothStep((doneAge - 150L) / 290f)) else 0f
                    crescent.mix(openEye(x, y - 0.016f, 0.32f, 0.49f, 1f,
                        0.15f, 0f, 0f, showBrow = false), pop)
                }
                Expression.ERROR -> {
                    val shake = if (motionEnabled) sin(age / 26.0).toFloat() *
                        (1f - age / 410f).coerceIn(0f, 1f) * 0.021f else 0f
                    Eye(Point(x + shake, y + side * 0.025f), 0f, 0f, 0f, 0f, 1f, 0f, 1f,
                        brow(x + shake, 0.205f + side * 0.015f, -side * 0.104f, 0.013f))
                }
                Expression.SLEEP -> {
                    val breath = if (motionEnabled) (1f - cos(2 * PI * age / 4200).toFloat()) / 2f else 0f
                    Eye(Point(x, y + 0.04f - breath * 0.018f),
                        0.126f + breath * 0.008f, 0.014f + breath * 0.005f,
                        -0.065f - breath * 0.019f, 0f, 1f, 0f, 0f,
                        brow(x, 0.33f, 0f, 0.019f, 0f))
                }
                Expression.FOCUS -> {
                    val proximity = ((pupilGaze.x * side - 0.045f) / 0.68f).coerceIn(0f, 1f)
                    val near = proximity * proximity * (3f - 2f * proximity)
                    val voice = listeningEnergy ?: 0f
                    val raised = if (listeningEnergy != null) 0.024f else 0f
                    val accent = voice * sin(time / 290f)
                    openEye(x, y - raised - 0.055f * voice + side * 0.017f * accent,
                        (0.253f + 0.048f * voice) * (1f - near * 0.14f),
                        (0.401f + 0.145f * voice) * (1f - near * 0.24f),
                        blink, 0.172f - raised - 0.054f * voice + near * 0.048f,
                        -side * (0.108f - 0.068f * voice) + 0.11f * accent, 0.026f + voice * 0.043f)
                }
                Expression.HELLO -> {
                    if (speechBeat != null) {
                        openEye(x, y - 0.045f + 0.039f * speechBeat, 0.303f,
                            0.405f + 0.073f * speechBeat, blink, 0.142f - 0.049f * speechBeat,
                            -side * 0.12f, 0.060f)
                    } else {
                        val hop = if (motionEnabled) pulse(age, 680L) else 0f
                        val wink = if (left && motionEnabled) 1f - 0.89f * pulse(age - 410L, 520L) else 1f
                        openEye(x, y - hop * 0.052f + if (left) 0.020f else 0f, 0.29f,
                            if (left) 0.403f else 0.458f, wink, 0.145f - hop * 0.04f, 0f, 0.035f,
                            showBrow = false)
                    }
                }
            }
        }
        return Face(eye(-1), eye(1), palettes.getValue(expression))
    }

    private fun sleepPeekEye(closed: Eye, awake: Eye, age: Long): Eye {
        fun ease(elapsed: Long, duration: Long): Float {
            val fraction = (elapsed.toFloat() / duration).coerceIn(0f, 1f)
            return fraction * fraction * (3f - 2f * fraction)
        }

        val flattening = ease(min(age, SLEEP_PEEK_CLOSED_AT - age), SLEEP_FLATTEN_DURATION)
        val opening = min(
            ease(age - SLEEP_FLATTEN_DURATION, SLEEP_PEEK_OPEN_DURATION),
            ease(SLEEP_PEEK_CLOSE_END - age, SLEEP_PEEK_CLOSE_DURATION)
        )
        val flatEye = closed.copy(bend = blend(closed.bend, 0f, flattening))
        return flatEye.mix(awake.copy(halfLid = 1f), opening)
    }

    private fun pulse(age: Long, duration: Long): Float =
        sin((age.toFloat() / duration).coerceIn(0f, 1f) * PI).toFloat()

    private fun drawEye(
        canvas: Canvas, eye: Eye, w: Float, h: Float, gaze: Point, codeAge: Long?, innerAtEnd: Boolean
    ) {
        val cx = eye.center.x * w
        val cy = eye.center.y * h
        val rx = eye.halfWidth * w
        val ry = eye.halfHeight * h
        if (rx > 0.5f && ry > 0.5f) {
            val top = cy - ry * (1f - eye.halfLid * 0.52f)
            val bottom = cy + ry * (1f - eye.halfLid)
            val corner = min(rx * 0.92f, min(ry, (bottom - top) * 0.68f)) * eye.roundness
            val bend = eye.bend * h
            val restBend = min(0f, bend)
            val lowerInset = eye.lowerInset * h + eye.halfLid * ry * 0.035f

            // 半睁眼保留胶囊的上半轮廓，下眼睑横跨两侧并略向上收。
            val insetAmount = (eye.lowerInset / 0.019f).coerceIn(0f, 1f)
            val insetCorner = blend(corner, min(corner, rx * 0.24f), insetAmount)
            val lowerCorner = blend(insetCorner, min(insetCorner, rx * 0.10f), eye.halfLid)
            val leftLift = max(0f, -eye.cheekLift) * h
            val rightLift = max(0f, eye.cheekLift) * h
            val topShoulder = restBend * corner / rx * 0.8f
            val bottomShoulder = restBend * lowerCorner / rx * 0.8f
            val leftBottom = bottom - leftLift
            val rightBottom = bottom - rightLift
            val cap = corner * 0.55f
            val bottomCap = lowerCorner * 0.55f
            val leftShoulderX = cx - rx + lowerCorner
            val rightShoulderX = cx + rx - lowerCorner
            val leftShoulderY = leftBottom - bottomShoulder
            val rightShoulderY = rightBottom - bottomShoulder
            val lowerControl = bottom - restBend + bottomShoulder - lowerInset * 2f
            val rightControlY = blend(rightShoulderY, lowerControl, 2f / 3f) - rightLift * insetAmount * 0.45f
            val leftControlY = blend(leftShoulderY, lowerControl, 2f / 3f) - leftLift * insetAmount * 0.45f

            // 睡眠弧线与两侧圆角以相同切线连接，避免睁眼时在接点形成尖角。
            fun smoothLid(fromX: Float, fromY: Float, middleY: Float, toX: Float, toY: Float) {
                outline.cubicTo(blend(fromX, cx, 0.40f), fromY,
                    blend(fromX, cx, 0.60f), middleY, cx, middleY)
                outline.cubicTo(blend(cx, toX, 0.40f), middleY,
                    blend(cx, toX, 0.60f), toY, toX, toY)
            }

            val topEdge = top - topShoulder
            outline.rewind()
            outline.moveTo(cx - rx + corner, topEdge)
            if (restBend < 0f) {
                val middleY = blend(topEdge, top - restBend * 0.5f, 1f - corner / rx)
                smoothLid(cx - rx + corner, topEdge, middleY, cx + rx - corner, topEdge)
            } else {
                outline.lineTo(cx + rx - corner, topEdge)
            }
            outline.cubicTo(cx + rx - corner + cap, top - topShoulder,
                cx + rx, top + corner - cap, cx + rx, top + corner)
            outline.lineTo(cx + rx, rightBottom - lowerCorner)
            outline.cubicTo(cx + rx, rightBottom - lowerCorner + bottomCap,
                rightShoulderX + bottomCap, rightShoulderY, rightShoulderX, rightShoulderY)
            if (restBend < 0f) {
                val shoulderY = (rightShoulderY + leftShoulderY) * 0.5f
                val curveY = (shoulderY + 1.5f * (rightControlY + leftControlY)) * 0.25f
                val middleY = blend(shoulderY, curveY, 1f - lowerCorner / rx)
                smoothLid(rightShoulderX, rightShoulderY, middleY, leftShoulderX, leftShoulderY)
            } else {
                outline.cubicTo(blend(rightShoulderX, cx, 2f / 3f), rightControlY,
                    blend(leftShoulderX, cx, 2f / 3f), leftControlY, leftShoulderX, leftShoulderY)
            }
            outline.cubicTo(leftShoulderX - bottomCap, leftShoulderY,
                cx - rx, leftBottom - lowerCorner + bottomCap, cx - rx, leftBottom - lowerCorner)
            outline.lineTo(cx - rx, top + corner)
            outline.cubicTo(cx - rx, top + corner - cap,
                cx - rx + corner - cap, top - topShoulder, cx - rx + corner, top - topShoulder)
            outline.close()
            val smileAngle = eye.bend * 3.25f
            val silhouette = if (eye.crescent > 0f && smileAngle > 0.004f)
                bendCapsule(cx, cy, rx, smileAngle, eye.crescent) else outline
            matrix.setScale(rx, ry + abs(bend) / 4f)
            matrix.postTranslate(cx, cy - bend / 4f)
            eyeFillShader?.setLocalMatrix(matrix)
            fillPaint.shader = eyeFillShader
            drawEyeHalo(canvas, silhouette, eyeFillShader, h)
            canvas.drawPath(silhouette, fillPaint)

            if (eye.pupil > 0.04f) {
                val frame = canvas.save()
                canvas.clipPath(silhouette)
                canvas.translate(gaze.x * rx * 0.24f, gaze.y * ry * 0.22f)
                val codeBlend = if (codeAge == null) 0f else {
                    (min(codeAge, THINK_CODE_DURATION - codeAge).toFloat() / CODE_TRANSITION_DURATION)
                        .coerceIn(0f, 1f)
                }
                if (codeBlend < 1f) {
                    val normal = canvas.save()
                    canvas.scale(PUPIL_SCALE, PUPIL_SCALE, cx, cy)
                    // 一层层叠亮同一轮廓，让瞳光从柔和的边缘过渡到白色中心。
                    pupilPaint.color = Color.WHITE
                    for ((index, alpha) in glowStops.withIndex()) {
                        val t = index.toFloat() / glowStops.lastIndex
                        val layer = canvas.save()
                        canvas.scale(blend(0.995f, 0.69f, t), blend(0.99f, 0.65f, t), cx, cy)
                        pupilPaint.alpha = (alpha * eye.pupil * (1f - codeBlend)).toInt()
                        canvas.drawPath(silhouette, pupilPaint)
                        canvas.restoreToCount(layer)
                    }
                    canvas.restoreToCount(normal)
                }
                if (codeAge != null && codeBlend > 0f) {
                    drawCodePupil(canvas, cx, cy, rx * PUPIL_SCALE, ry * PUPIL_SCALE, codeAge, codeBlend)
                }
                canvas.restoreToCount(frame)
            }
        }
        if (eye.cross > 0.001f) {
            val x = eye.center.x
            val y = eye.center.y
            val spanX = 0.069f * eye.cross
            val spanY = 0.115f * eye.cross
            val width = 0.069f * eye.cross
            drawStroke(canvas, line(x - spanX, y - spanY, x + spanX, y + spanY, width), w, h, 255, glow = eye.cross)
            drawStroke(canvas, line(x + spanX, y - spanY, x - spanX, y + spanY, width), w, h, 255, glow = eye.cross)
        }
        drawBrow(canvas, eye.brow, w, h, innerAtEnd)
    }

    private fun drawCodePupil(canvas: Canvas, cx: Float, cy: Float,
                              rx: Float, ry: Float, age: Long, progress: Float) {
        matrix.setScale(rx, ry)
        matrix.postTranslate(cx, cy)
        codeBackdrop.setLocalMatrix(matrix)
        codePaint.shader = codeBackdrop
        codePaint.alpha = (255 * progress).toInt()
        canvas.drawOval(cx - rx, cy - ry, cx + rx, cy + ry, codePaint)
        codePaint.shader = null

        val columnWidth = 2f * rx / 7f
        val rowHeight = 2f * ry / 10f
        codePaint.textSize = min(columnWidth, rowHeight) * 0.86f
        val glyphCenter = (codePaint.ascent() + codePaint.descent()) / 2f
        for (column in 0..6) {
            val x = cx + (column - 3) * columnWidth
            val travel = (age + cx.toLong() * 3L) / (115f + (column % 3) * 33f) + column * 2.3f
            val wholeRows = travel.toInt()
            val offset = (travel - wholeRows) * rowHeight
            for (row in -1..10) {
                val y = cy - ry + row * rowHeight + offset
                val dx = (x - cx) / rx
                val dy = (y - cy) / ry
                val edgeFade = ((1f - dx * dx - dy * dy) / 0.55f).coerceIn(0f, 1f)
                if (edgeFade == 0f) continue
                val streamRow = row - wholeRows
                val tail = (streamRow + column * 3).mod(7)
                val revealAt = 0.20f + (row * 11 + column * 17).mod(13) * 0.05f
                if (progress < revealAt) {
                    val tileHalfSize = min(columnWidth, rowHeight) * 0.42f
                    codePaint.color = 0xFF43FF8B.toInt()
                    codePaint.alpha = (215 * edgeFade * progress / revealAt).toInt()
                    canvas.drawRect(x - tileHalfSize, y - tileHalfSize, x + tileHalfSize, y + tileHalfSize, codePaint)
                } else {
                    codePaint.color = if (tail == 0) 0xFFDCFFD8.toInt() else 0xFF4BFF83.toInt()
                    codePaint.alpha = ((255 - tail * 27) * edgeFade).toInt()
                    val bit = (streamRow xor (streamRow shr 2) xor column) and 1
                    canvas.drawText(if (bit == 0) "0" else "1", x, y - glyphCenter, codePaint)
                }
            }
        }
    }

    private fun bendCapsule(cx: Float, cy: Float, radius: Float, halfAngle: Float, smile: Float): Path {
        // Bend the capsule along a circular arc and make its center a little fuller.
        val bendRadius = radius / halfAngle
        val endCos = cos(halfAngle)
        outlineMeasure.setPath(outline, true)
        curvedOutline.rewind()
        val length = outlineMeasure.length
        for (index in 0 until 96) {
            outlineMeasure.getPosTan(length * index / 96f, outlinePoint, null)
            val u = ((outlinePoint[0] - cx) / radius).coerceIn(-1f, 1f)
            val angle = u * halfAngle
            val thickness = 1f + (0.20f - 0.31f * u * u) * smile
            val offset = (outlinePoint[1] - cy) * thickness
            val x = cx + (bendRadius - offset) * sin(angle)
            val y = cy + bendRadius * (endCos - cos(angle)) + offset * cos(angle)
            if (index == 0) curvedOutline.moveTo(x, y) else curvedOutline.lineTo(x, y)
        }
        curvedOutline.close()
        return curvedOutline
    }

    private fun updateEyeShaders(palette: Palette) {
        if (currentPalette == palette) return
        currentPalette = palette
        val colors = intArrayOf(palette.top, palette.middle, palette.bottom)
        val stops = floatArrayOf(0f, 0.52f, 1f)
        eyeFillShader = RadialGradient(0f, 0f, 1f, colors, stops, Shader.TileMode.CLAMP)
        strokeShader = LinearGradient(0f, 0f, 0.85f, 1f, colors, stops, Shader.TileMode.CLAMP)
    }

    private fun drawEyeHalo(canvas: Canvas, contour: Path, shader: Shader?, h: Float,
                            strokeWidth: Float = 0f, strength: Float = 1f) {
        eyeHaloPaint.shader = shader
        val widthStep = 2f * h * EYE_HALO_RADIUS / EYE_HALO_ALPHA.size
        // 先画最淡的外层，逐层向原轮廓收拢。
        for (index in EYE_HALO_ALPHA.indices) {
            eyeHaloPaint.strokeWidth = strokeWidth + widthStep * (EYE_HALO_ALPHA.size - index)
            eyeHaloPaint.alpha = (EYE_HALO_ALPHA[index] * strength).toInt()
            canvas.drawPath(contour, eyeHaloPaint)
        }
    }

    private fun drawBrow(canvas: Canvas, brow: Stroke, w: Float, h: Float, innerAtEnd: Boolean) {
        if (brow.width < 0.001f) return
        val start = brow.start
        val control = brow.control
        val end = brow.end
        val thickness = brow.width * h
        val outerRadius = thickness * 0.32f
        val innerRadius = thickness * 0.72f
        val segments = 16
        path.rewind()

        // 沿现有眉弧的法线描出两侧轮廓，内侧逐渐变粗。
        fun edge(index: Int, side: Float): Point {
            val t = index.toFloat() / segments
            val inner = if (innerAtEnd) t else 1f - t
            val radius = blend(outerRadius, innerRadius, inner) * side
            val a = start.mix(control, t)
            val b = control.mix(end, t)
            val center = a.mix(b, t)
            val dx = (b.x - a.x) * w
            val dy = (b.y - a.y) * h
            val normal = radius / hypot(dx, dy)
            return Point(center.x * w + dy * normal, center.y * h - dx * normal)
        }

        fun roundTip(index: Int, tip: Point, side: Float) {
            val from = edge(index, side)
            val to = edge(index, -side)
            val dx = (tip.x - control.x) * w
            val dy = (tip.y - control.y) * h
            val extension = hypot(to.x - from.x, to.y - from.y) * 2f / (3f * hypot(dx, dy))
            path.cubicTo(from.x + dx * extension, from.y + dy * extension,
                to.x + dx * extension, to.y + dy * extension, to.x, to.y)
        }

        val first = edge(0, 1f)
        path.moveTo(first.x, first.y)
        for (index in 1..segments) {
            val point = edge(index, 1f)
            path.lineTo(point.x, point.y)
        }
        roundTip(segments, end, 1f)
        for (index in (segments - 1) downTo 0) {
            val point = edge(index, -1f)
            path.lineTo(point.x, point.y)
        }
        roundTip(0, start, -1f)
        path.close()

        val left = minOf(start.x, control.x, end.x) * w
        val right = maxOf(start.x, control.x, end.x) * w
        val top = minOf(start.y, control.y, end.y) * h
        val bottom = maxOf(start.y, control.y, end.y) * h
        matrix.setScale(right - left + thickness, bottom - top + thickness)
        matrix.postTranslate(left - thickness / 2f, top - thickness / 2f)
        strokeShader?.setLocalMatrix(matrix)
        val strength = (brow.width / 0.024f).coerceIn(0f, 1f)
        drawEyeHalo(canvas, path, strokeShader, h * 0.70f, strength = strength * 0.85f)
        browPaint.shader = strokeShader
        browPaint.alpha = 207
        canvas.drawPath(path, browPaint)
    }

    private fun drawStroke(canvas: Canvas, stroke: Stroke, w: Float, h: Float, alpha: Int, glow: Float = 0f) {
        if (stroke.width < 0.001f) return
        val left = minOf(stroke.start.x, stroke.control.x, stroke.end.x) * w
        val top = minOf(stroke.start.y, stroke.control.y, stroke.end.y) * h
        val right = maxOf(stroke.start.x, stroke.control.x, stroke.end.x) * w
        val bottom = maxOf(stroke.start.y, stroke.control.y, stroke.end.y) * h
        val thickness = stroke.width * h
        matrix.setScale(right - left + thickness, bottom - top + thickness)
        matrix.postTranslate(left - thickness / 2f, top - thickness / 2f)
        strokeShader?.setLocalMatrix(matrix)
        strokePaint.shader = strokeShader
        strokePaint.alpha = alpha
        strokePaint.strokeWidth = thickness
        path.rewind()
        path.moveTo(stroke.start.x * w, stroke.start.y * h)
        path.quadTo(stroke.control.x * w, stroke.control.y * h, stroke.end.x * w, stroke.end.y * h)
        if (glow > 0f) drawEyeHalo(canvas, path, strokeShader, h, thickness, glow)
        canvas.drawPath(path, strokePaint)
    }

    private fun drawDetails(canvas: Canvas, expression: Expression, status: EyeState, color: Palette,
                            time: Long, w: Float, h: Float, progress: Float) {
        val celebrationAge = time - if (status == EyeState.DONE) donePresentedAt else morphStart
        when {
            expression == Expression.DONE && motionEnabled && celebrationAge in 0..720 -> {
                val travel = (celebrationAge / 720f).coerceIn(0f, 1f)
                detailPaint.color = color.top
                detailPaint.alpha = (200 * sin(travel * PI)).toInt()
                val y = h * (0.33f - travel * 0.18f)
                for (side in -1..1 step 2) {
                    val x = w * (0.5f + side * (0.28f + travel * 0.12f))
                    val size = h * (0.01f + travel * 0.012f)
                    canvas.drawCircle(x, y, size, detailPaint)
                }
            }
            expression == Expression.QUESTION -> {
                detailPaint.color = color.top
                detailPaint.textSize = h * 0.18f
                val smallRight = smallEyeOnRight()
                val x = (blend(0.19f, 0.81f, smallRight) + gaze.x).coerceIn(0.08f, 0.92f)
                val lift = (1f - abs(2f * smallRight - 1f)) * 0.035f
                canvas.drawText("?", w * x, h * (0.24f - 0.05f * progress + gaze.y - lift), detailPaint)
            }
            expression == Expression.IDEA -> {
                detailPaint.color = 0xFFFFE491.toInt()
                detailPaint.textSize = h * (0.165f + pulse(time - morphStart, 550L) * 0.026f)
                canvas.drawText("!", w * 0.86f, h * 0.225f, detailPaint)
            }
            expression == Expression.SLEEP -> {
                detailPaint.color = color.top
                if (motionEnabled) {
                    val age = time - morphStart
                    for (i in 0..1) {
                        val drift = ((age + 640L + i * 1440L) % 3200L) / 3200f
                        detailPaint.alpha = (185 * sin(drift * PI) * progress).toInt()
                        detailPaint.textSize = h * (0.077f + drift * 0.039f)
                        val baseline = h * (0.33f - drift * 0.20f) -
                            (detailPaint.ascent() + detailPaint.descent()) / 2f
                        canvas.drawText(if (i == 0) "Z" else "z", w * (0.76f + drift * 0.14f),
                            baseline, detailPaint)
                    }
                } else {
                    detailPaint.alpha = 151
                    detailPaint.textSize = h * 0.11f
                    canvas.drawText("Z", w * 0.79f, h * 0.29f, detailPaint)
                    detailPaint.alpha = 100
                    detailPaint.textSize = h * 0.083f
                    canvas.drawText("z", w * 0.865f, h * 0.21f, detailPaint)
                }
            }
            else -> Unit
        }
    }

    private fun nextThinkingLook(time: Long, previous: ThinkingLook?): ThinkingLook {
        val step = (previous?.step ?: -1) + 1
        if (step == READING_STOPS.size) {
            return ThinkingLook(null, time, time + THINK_CODE_SETTLE + THINK_CODE_DURATION,
                105f, gaze, pupilGaze, Point(0f, 0f), null)
        }
        val stop = READING_STOPS[step]
        val target = stop.direction.shift(Point(Random.nextFloat() * 0.10f - 0.05f,
            Random.nextFloat() * 0.08f - 0.04f))
        val blinkAt = stop.blinkDelay?.let { time + it + Random.nextLong(0L, 36L) }
        return ThinkingLook(step, time, time + Random.nextLong(stop.minHold, stop.maxHold),
            stop.moveDuration, gaze, pupilGaze, target, blinkAt)
    }

    private fun thinkingBlink(time: Long, look: ThinkingLook): Float {
        val age = time - (look.blinkAt ?: return 1f)
        val closure = if (age < 65L) smoothStep(age / 65f) else 1f - smoothStep((age - 65L) / 120f)
        return 1f - 0.92f * closure
    }

    private fun blinkDelay(idle: Boolean): Long =
        if (idle) Random.nextLong(1900L, 4000L) else Random.nextLong(2600L, 5700L)

    private fun scheduleBlink(time: Long, delay: Long) {
        nextBlinkAt = time + delay
        blinkStarted = 0L
        doubleBlink = Random.nextInt(4) == 0
    }

    private fun blink(time: Long, idle: Boolean = false): Float {
        if (blinkStarted == 0L) {
            if (time < nextBlinkAt) return 1f
            blinkStarted = time
        }
        val age = time - blinkStarted
        val phase = when {
            age < BLINK_DURATION -> age.toFloat() / BLINK_DURATION
            doubleBlink && age < 255L -> return 1f
            doubleBlink && age < 425L -> (age - 255L) / 170f
            else -> {
                scheduleBlink(time, blinkDelay(idle))
                return 1f
            }
        }
        return blinkOpenness(phase)
    }

    private fun blinkOpenness(phase: Float): Float = 1f - 0.92f * sin(phase * PI).toFloat()

    companion object {
        private val IDLE_REACTIONS = listOf(Expression.DONE, Expression.HELLO, Expression.IDEA)
        private val EYE_HALO_ALPHA = intArrayOf(2, 3, 4, 5, 7, 9, 12, 15, 18, 21, 24, 27)
        private const val EYE_HALO_RADIUS = 0.038f
        private const val FACE_ASPECT = 624f / 596f
        private const val REAR_FACE_ASPECT = 652f / 596f
        private const val EYE_SPACING = 0.18f
        private const val NARROW_EYE_SPACING = 0.143f
        private const val EYE_CENTER_Y = 0.445f
        // 沿用追踪表情的小瞳孔比例，随当前帧的眼睛轮廓缩放。
        private const val PUPIL_SCALE = 0.76f * 0.86f
        private const val TAP_DURATION = 850L
        private const val DEEP_SLEEP_DELAY = 300_000L
        private const val SECOND_TAP_WINDOW = 4_000L
        private const val SLEEP_FLATTEN_DURATION = 160L
        private const val SLEEP_PEEK_OPEN_DURATION = 420L
        private const val SLEEP_PEEK_HOLD = 500L
        private const val SLEEP_PEEK_CLOSE_DURATION = 250L
        private const val SLEEP_PEEK_CLOSE_END =
            SLEEP_FLATTEN_DURATION + SLEEP_PEEK_OPEN_DURATION + SLEEP_PEEK_HOLD + SLEEP_PEEK_CLOSE_DURATION
        private const val SLEEP_PEEK_CLOSED_AT = SLEEP_PEEK_CLOSE_END + SLEEP_FLATTEN_DURATION
        private const val SLEEP_CLOSED_HOLD = 200L
        private const val SLEEP_PEEK_DURATION = SLEEP_PEEK_CLOSED_AT + SLEEP_CLOSED_HOLD
        private const val SLEEP_WAKE_DURATION = 580L
        private const val STILL_LOOK_DELAY = 1500L
        private const val PUZZLED_DURATION = 950L
        private const val RELEASE_DURATION = 390L
        private const val GREETING_DURATION = 1400L
        private val READING_STOPS = listOf(
            ReadingStop(Point(-0.86f, -0.29f), 145f, 370L, 505L),
            ReadingStop(Point(-0.18f, -0.26f), 65f, 185L, 265L),
            ReadingStop(Point(0.70f, -0.22f), 95f, 510L, 680L),
            ReadingStop(Point(-0.77f, 0.42f), 80f, 365L, 510L, blinkDelay = 10L),
            ReadingStop(Point(0.06f, 0.44f), 70f, 200L, 300L),
            ReadingStop(Point(0.81f, 0.46f), 180f, 680L, 900L),
            ReadingStop(Point(0.40f, -0.57f), 220f, 850L, 1120L, blinkDelay = 375L),
        )
        private const val THINK_CODE_SETTLE = 200L
        private const val THINK_CODE_DURATION = 2000L
        private const val CODE_TRANSITION_DURATION = 240L
        private const val BLINK_DURATION = 185L

        private fun blend(from: Float, to: Float, t: Float) = from + (to - from) * t
        private fun smoothStep(value: Float): Float {
            val t = value.coerceIn(0f, 1f)
            return t * t * (3f - 2f * t)
        }
        private fun palette(a: Int, b: Int, c: Int) = Palette(a or Color.BLACK, b or Color.BLACK, c or Color.BLACK)
        private fun mixColor(from: Int, to: Int, t: Float) = Color.rgb(
            blend(Color.red(from).toFloat(), Color.red(to).toFloat(), t).toInt(),
            blend(Color.green(from).toFloat(), Color.green(to).toFloat(), t).toInt(),
            blend(Color.blue(from).toFloat(), Color.blue(to).toFloat(), t).toInt()
        )

        private fun curve(x1: Float, y1: Float, cx: Float, cy: Float, x2: Float, y2: Float, width: Float) =
            Stroke(Point(x1, y1), Point(cx, cy), Point(x2, y2), width)

        private fun line(x1: Float, y1: Float, x2: Float, y2: Float, width: Float) =
            curve(x1, y1, (x1 + x2) / 2f, (y1 + y2) / 2f, x2, y2, width)

        private fun brow(x: Float, y: Float, tilt: Float, arch: Float, width: Float = 0.024f) =
            curve(x - 0.077f, y - tilt / 2f, x, y - arch, x + 0.077f, y + tilt / 2f, width)
    }
}
