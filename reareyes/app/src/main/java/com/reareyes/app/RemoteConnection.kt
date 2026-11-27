package com.reareyes.app

import android.content.Context
import android.net.Uri
import android.os.Build
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

internal object RemoteConnection {
    data class Pairing(val url: String, val token: String, val desktopId: String? = null, val desktopName: String? = null)
    data class Feedback(val updatedAt: Long? = null, val state: EyeState? = null, val error: String? = null)

    private val tokenPattern = Regex("[A-Za-z0-9_-]{43}")
    private const val prefs = "remote_connection"

    @Volatile
    private var visibleScreens = 0
    @Volatile
    var feedback = Feedback()
        private set
    private var lanAttemptAt = 0L

    fun screenStarted() { visibleScreens++ }
    fun screenStopped() { visibleScreens-- }

    fun parse(raw: String): Pairing {
        val value = JSONObject(raw)
        val uri = URI(value.getString("url").trim())
        val host = requireNotNull(uri.host)
        require(uri.scheme == "https" && host.endsWith(".ts.net") &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port in 1..65535) && uri.path in listOf("", "/"))
        val token = value.getString("token")
        require(tokenPattern.matches(token))
        return Pairing(uri.toASCIIString().trimEnd('/'), token,
            value.optString("desktopId").ifBlank { null }, value.optString("desktopName").ifBlank { null })
    }

    fun json(pairing: Pairing): JSONObject = JSONObject().put("url", pairing.url).put("token", pairing.token)
        .put("desktopId", pairing.desktopId).put("desktopName", pairing.desktopName)

    fun load(context: Context): Pairing? {
        val raw = context.getSharedPreferences(prefs, Context.MODE_PRIVATE).getString("pairing", null)
        return try {
            raw?.let(::parse)
        } catch (_: Exception) {
            null
        }
    }

    fun saveFromUsb(context: Context, pairing: Pairing) {
        DesktopProfiles.remember(context, pairing.desktopId, pairing.desktopName, remote = pairing)
    }

    @Synchronized
    fun save(context: Context, pairing: Pairing?) {
        val raw = pairing?.let { json(it).toString() }
        context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
            .edit().putString("pairing", raw).apply()
        feedback = Feedback()
        lanAttemptAt = 0L
        EyesBus.clearDesktopSnapshot(EyesBus.Transport.TAILSCALE)
    }

    fun startPolling(context: Context) = Executors.newSingleThreadScheduledExecutor().apply {
        scheduleWithFixedDelay({
            if (visibleScreens > 0) load(context)?.let { refresh(context, it) }
        }, 0, 4, TimeUnit.SECONDS)
    }

    private fun refresh(context: Context, pairing: Pairing) {
        try {
            val ticket = EyesBus.syncTicket
            val snapshot = request(pairing, "/status", phoneId = phoneId(context))
            if (load(context) == pairing) {
                val desktop = DesktopProfiles.remember(context, snapshot.optString("desktopId"),
                    snapshot.optString("desktopName"), remote = pairing,
                    lanKey = LanMcpSettings.validKey(snapshot.optString("lanKey")), trustedKey = true)
                if (DesktopProfiles.active(context)?.key != desktop.key) return
            }
            val state = EyeState.valueOf(snapshot.getString("state"))
            fun usage(name: String): EyesBus.UsageWindow? {
                val used = snapshot.optInt(name, -1)
                val reset = snapshot.optLong(name + "Reset", -1L)
                return if (used in 0..100 && reset > 0) EyesBus.UsageWindow(used, reset) else null
            }
            synchronized(this) {
                if (load(context) == pairing && !Thread.currentThread().isInterrupted) {
                    EyesBus.setDesktopSnapshot(EyesBus.Transport.TAILSCALE, state,
                        EyesBus.Usage(usage("five"), usage("week")), ticket,
                        EyesBus.readAgentStates(snapshot.optJSONObject("agents")),
                        EyesBus.readModelConnections(snapshot.optJSONArray("models")))
                    feedback = Feedback(updatedAt = System.currentTimeMillis(), state = state)
                }
            }
            offerLan(context, pairing)
        } catch (error: Exception) {
            synchronized(this) {
                if (load(context) == pairing && !Thread.currentThread().isInterrupted) {
                    feedback = feedback.copy(error = describe(error))
                }
            }
        }
    }

    private fun offerLan(context: Context, pairing: Pairing) {
        if (LanMcpSettings.settingsReady(context)) return
        val address = LanMcpSettings.endpoints(context).firstOrNull()?.let { URI(it).host } ?: return
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(this) {
            if (load(context) != pairing || (lanAttemptAt != 0L && now - lanAttemptAt < 30_000L)) return
            lanAttemptAt = now
        }
        try {
            request(pairing, "/lan/pair", JSONObject().put("address", address)
                .put("token", LanMcpSettings.token(context)).put("phoneKey", LanMcpSettings.publicKey(context))
                .put("phoneName", Build.MODEL))
        } catch (_: Exception) {
            // Older desktop versions can keep using Tailscale.
        }
    }

    fun send(pairing: Pairing, id: String, text: String) {
        val payload = JSONObject().put("id", id).put("text", text)
        if (request(pairing, "/messages", payload).optString("id") != id) {
            throw IOException("Message receipt mismatch")
        }
    }

    fun describe(error: Exception): String = when ((error as? HttpFailure)?.status) {
        401 -> "配对密钥无效，请从电脑重新复制配置。"
        409 -> "这条消息的编号已使用，请重新输入。"
        500 -> "电脑无法保存消息，请检查桌面端。"
        else -> "连接失败，请检查 Tailscale 和电脑服务。"
    }

    @Synchronized
    private fun phoneId(context: Context): String {
        val settings = context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
        return settings.getString("phoneId", null) ?: UUID.randomUUID().toString().also {
            settings.edit().putString("phoneId", it).apply()
        }
    }

    private fun request(pairing: Pairing, path: String, body: JSONObject? = null,
                        phoneId: String? = null): JSONObject {
        val connection = URI(pairing.url + path).toURL().openConnection() as HttpsURLConnection
        try {
            connection.connectTimeout = 4000
            connection.readTimeout = 4000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Authorization", "Bearer " + pairing.token)
            if (phoneId != null) {
                connection.setRequestProperty("X-Robot-Eyes-Phone-Id", phoneId)
                connection.setRequestProperty("X-Robot-Eyes-Phone-Name", Uri.encode(Build.MODEL))
            }
            if (body != null) {
                val bytes = body.toString().toByteArray(Charsets.UTF_8)
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val code = connection.responseCode
            if (code !in 200..201) throw HttpFailure(code)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                val result = StringBuilder()
                val buffer = CharArray(1024)
                while (true) {
                    val count = reader.read(buffer)
                    if (count < 0) break
                    if (result.length + count > 16_384) throw IOException("Response too large")
                    result.append(buffer, 0, count)
                }
                JSONObject(result.toString())
            }
        } finally {
            connection.disconnect()
        }
    }

    private class HttpFailure(val status: Int) : IOException()
}
