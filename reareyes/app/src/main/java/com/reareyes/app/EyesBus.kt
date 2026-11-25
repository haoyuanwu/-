package com.reareyes.app

import android.os.SystemClock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

object EyesBus {

    data class UsageWindow(val usedPercent: Int, val resetsAt: Long?) {
        fun activePercent(nowSeconds: Long): Int? =
            usedPercent.takeUnless { resetsAt != null && resetsAt <= nowSeconds }

        fun remainingPercent(nowSeconds: Long): Int? =
            activePercent(nowSeconds)?.let { 100 - it }
    }

    data class Usage(val fiveHour: UsageWindow?, val week: UsageWindow?)

    @Volatile
    private var localUsage = Usage(null, null)

    enum class Transport(val label: String) {
        USB("USB"), LAN("局域网"), TAILSCALE("Tailscale")
    }

    private data class DesktopSnapshot(
        val state: EyeState, val usage: Usage, val expiresAt: Long, val agents: Map<String, EyeState>,
    )
    private val desktop = mutableMapOf<Transport, DesktopSnapshot>()

    val usage: Usage
        @Synchronized get() = activeDesktop(SystemClock.elapsedRealtime())?.second?.usage ?: localUsage

    val connectedUsage: Usage?
        @Synchronized get() = activeDesktop(SystemClock.elapsedRealtime())?.second?.usage

    @Synchronized
    fun connectedTransports(): List<Transport> {
        val now = SystemClock.elapsedRealtime()
        return Transport.entries.filter { (desktop[it]?.expiresAt ?: 0L) > now }
    }

    @Synchronized
    fun setDesktopSnapshot(
        source: Transport, value: EyeState?, usage: Usage, ticket: String = syncTicket,
        agents: Map<String, EyeState> = emptyMap(),
    ) {
        val now = SystemClock.elapsedRealtime()
        desktop[source] = DesktopSnapshot(value ?: desktop[source]?.state ?: localState, usage, now + 12_000L, agents)
        refreshState(now, source.label)
        if (ticket == syncTicket && ticket != syncedTicket && activeDesktop(now)?.first == source) {
            syncedTicket = ticket
            log("${source.label} 已同步")
        }
    }

    @Synchronized
    fun clearDesktopSnapshot(source: Transport) {
        desktop.remove(source)
        refreshState(SystemClock.elapsedRealtime(), source.label)
    }

    private fun activeDesktop(now: Long): Pair<Transport, DesktopSnapshot>? =
        Transport.entries.firstNotNullOfOrNull { source ->
            desktop[source]?.takeIf { it.expiresAt > now }?.let { source to it }
        }

    fun updateUsage(snapshot: Usage) {
        localUsage = snapshot
    }


    @Volatile
    var syncTicket = UUID.randomUUID().toString()
        private set

    @Volatile
    var syncedTicket: String? = null
        private set

    fun requestSync(): String {
        val ticket = UUID.randomUUID().toString()
        syncTicket = ticket
        return ticket
    }

    fun syncFromCodex(
        ticket: String, state: EyeState?, snapshot: Usage, source: Transport?,
        agents: Map<String, EyeState> = emptyMap(),
    ) {
        if (ticket != syncTicket) return
        if (source != null) {
            setDesktopSnapshot(source, state, snapshot, ticket, agents)
            return
        }
        updateUsage(snapshot)
        state?.let { set(it, "Codex") }
        syncedTicket = ticket
        log("Codex 已同步")
    }

    @Volatile
    var greetedAt: Long = 0L
        private set

    fun greet() {
        greetedAt = SystemClock.elapsedRealtime()
    }

    @Volatile
    var state: EyeState = EyeState.IDLE
        private set

    @Volatile
    var stateSince: Long = SystemClock.elapsedRealtime()
        private set

    private var stateRevision = 0L
    private var localState = EyeState.IDLE
    private var localStateSince = stateSince
    private var idleTimeout = 90_000L
    private var desktopWakeAt: Long? = null
    private var preview: Pair<EyeState, Long>? = null

    private fun previewUntil(state: EyeState, now: Long): Long = when (state) {
        EyeState.IDLE, EyeState.SLEEP -> now + idleTimeout
        EyeState.DONE, EyeState.ERROR, EyeState.STOPPED -> now + 30_000L
        else -> now + 5_000L
    }

    @Synchronized
    fun preview(value: EyeState) {
        val now = SystemClock.elapsedRealtime()
        preview = value to previewUntil(value, now)
        if (state == value) {
            stateRevision++
            stateSince = now
        }
        refreshState(now, "表情预览")
    }
    private data class AgentState(val state: EyeState, val expiresAt: Long)
    private val agents = mutableMapOf<Pair<String, String>, AgentState>()
    private val priority = listOf(EyeState.QUESTION, EyeState.THINKING, EyeState.ERROR, EyeState.DONE)
    private val agentPriority = priority + listOf(EyeState.STOPPED, EyeState.IDLE, EyeState.SLEEP)

    internal fun readAgentStates(json: JSONObject?): Map<String, EyeState> = buildMap {
        json?.keys()?.asSequence()?.take(24)?.forEach { name ->
            if (name.isNotBlank() && name.length <= 64 && name.none { it.isISOControl() }) {
                EyeState.entries.firstOrNull { it.name == json.opt(name) }?.let { put(name, it) }
            }
        }
    }

    @Synchronized
    fun agentStates(): Map<String, EyeState> {
        val now = SystemClock.elapsedRealtime()
        val combined = activeDesktop(now)?.second?.agents.orEmpty().toMutableMap()
        for ((key, task) in agents) {
            if (task.expiresAt <= now) continue
            val name = combined.keys.firstOrNull { it.equals(key.first, ignoreCase = true) } ?: key.first
            val current = combined[name]
            if (current == null || agentPriority.indexOf(task.state) < agentPriority.indexOf(current)) {
                combined[name] = task.state
            }
        }
        return combined.toSortedMap(String.CASE_INSENSITIVE_ORDER)
    }

    data class SleepSession(val revision: Long, val startedAt: Long)

    @Synchronized
    fun sleepSession(): SleepSession? =
        if (state == EyeState.SLEEP) SleepSession(stateRevision, stateSince) else null

    @Synchronized
    fun isSleeping(revision: Long): Boolean = state == EyeState.SLEEP && stateRevision == revision

    @Synchronized
    fun wakeFromSleep(revision: Long) {
        if (!isSleeping(revision)) return
        val now = SystemClock.elapsedRealtime()
        if (preview?.first == EyeState.SLEEP) preview = EyeState.IDLE to previewUntil(EyeState.IDLE, now)
        if (activeDesktop(now)?.second?.state == EyeState.SLEEP) desktopWakeAt = now
        set(EyeState.IDLE, "touch wake")
    }

    @Synchronized
    fun sleepIfInactive(idleTimeoutMs: Long) {
        idleTimeout = idleTimeoutMs
        val now = SystemClock.elapsedRealtime()
        val timeout = when (localState) {
            EyeState.DONE, EyeState.ERROR, EyeState.STOPPED -> 30_000L
            EyeState.IDLE -> idleTimeoutMs
            else -> Long.MAX_VALUE
        }
        if (now - localStateSince >= timeout) localState = EyeState.SLEEP
        refreshState(now, "auto-idle")
    }

    @Synchronized
    fun setAgentState(name: String, session: String, value: EyeState): EyeState? {
        val now = SystemClock.elapsedRealtime()
        agents.values.removeAll { it.expiresAt <= now }
        val key = name to session
        when (value) {
            EyeState.IDLE, EyeState.SLEEP -> agents.remove(key)
            else -> {
                if (key !in agents && agents.size >= 128) return null
                val lifetime = if (value == EyeState.QUESTION || value == EyeState.THINKING) 900_000L else 30_000L
                agents[key] = AgentState(value, now + lifetime)
            }
        }
        refreshState(now, "MCP")
        return state
    }

    @Synchronized
    fun clearAgentStates() {
        agents.clear()
        refreshState(SystemClock.elapsedRealtime(), "MCP")
    }

    private val logBuf = ArrayDeque<String>()

    @Volatile
    var onLog: ((String) -> Unit)? = null

    @Volatile
    var onCalibrate: (() -> Unit)? = null

    @Synchronized
    fun set(s: EyeState, src: String) {
        val now = SystemClock.elapsedRealtime()
        localState = s
        localStateSince = now
        refreshState(now, src, refreshTime = true)
    }

    private fun refreshState(now: Long, source: String, refreshTime: Boolean = false) {
        agents.values.removeAll { it.expiresAt <= now }
        val desktopState = activeDesktop(now)?.second?.state
        if (desktopState != EyeState.SLEEP) desktopWakeAt = null
        val wokeFromDesktopSleep = desktopWakeAt?.let { now - it < idleTimeout } == true
        val sourceState = if (wokeFromDesktopSleep) EyeState.IDLE else desktopState ?: localState
        if (preview?.let { it.second <= now } == true) preview = null
        val next = preview?.first ?: priority.firstOrNull { candidate ->
            candidate == sourceState || agents.values.any { it.state == candidate }
        } ?: sourceState
        if (state == next) {
            if (refreshTime && sourceState == localState && localState == next) {
                stateRevision++
                stateSince = now
            }
            return
        }
        stateRevision++
        state = next
        stateSince = now
        log("state -> $next (from $source)")
    }

    fun log(msg: String) {
        val line = "${ts()} $msg"
        synchronized(logBuf) {
            logBuf.addLast(line)
            while (logBuf.size > 300) logBuf.removeFirst()
        }
        onLog?.invoke(line)
    }

    fun dumpLog(n: Int = 60): List<String> = synchronized(logBuf) {
        if (logBuf.size <= n) logBuf.toList() else logBuf.takeLast(n)
    }

    private fun ts(): String =
        SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
}
