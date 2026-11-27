package com.reareyes.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.NetworkCapabilities
import android.os.PersistableBundle
import android.os.SystemClock
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.SocketTimeoutException
import java.net.Proxy
import java.net.URL
import java.util.UUID
import org.json.JSONObject

internal object LanMcpSettings {
    const val PORT = 8789
    private const val PREFS = "lan_mcp"
    private const val DESKTOP_PORT = 18794
    private var desktopSeenAt: Long? = null
    private var verifiedDesktop: String? = null
    private var configSync = false
    private var pairingInFlight = false
    private var nextPairingAt = 0L
    private var attemptedDesktop: String? = null

    fun enabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getBoolean("enabled", true)

    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled).apply()
        if (!enabled) {
            EyesBus.clearAgentStates()
        }
    }

    @Synchronized
    fun token(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getString("token", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("token", it).apply()
        }
    }

    fun endpoints(context: Context): List<String> = lanAddresses(context).map {
        "http://${it.address.hostAddress}:$PORT/mcp"
    }.distinct()

    fun discover(context: Context): List<Map<String, String>> {
        val links = lanAddresses(context)
        if (links.isEmpty()) return emptyList()
        val probe = "robot-eyes:1".toByteArray()
        val found = linkedMapOf<String, Map<String, String>>()
        try {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                for (link in links) {
                    val prefix = link.prefixLength
                    if (prefix !in 1..30) continue
                    val bytes = link.address.address.clone()
                    for (index in prefix until 32) {
                        val i = index / 8
                        bytes[i] = (bytes[i].toInt() or (1 shl (7 - index % 8))).toByte()
                    }
                    val broadcast = InetAddress.getByAddress(bytes)
                    runCatching { socket.send(DatagramPacket(probe, probe.size, broadcast, DESKTOP_PORT)) }
                }
                val deadline = SystemClock.elapsedRealtime() + 1200
                while (found.size < 12) {
                    val remaining = deadline - SystemClock.elapsedRealtime()
                    if (remaining <= 0) break
                    socket.soTimeout = remaining.toInt()
                    val packet = DatagramPacket(ByteArray(512), 512)
                    try {
                        socket.receive(packet)
                    } catch (_: SocketTimeoutException) {
                        break
                    }
                    val remote = packet.address
                    if (packet.port != DESKTOP_PORT || remote !is Inet4Address ||
                        links.none { sameSubnet(it.address, remote, it.prefixLength) }) continue
                    val reply = runCatching { JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8)) }
                        .getOrNull() ?: continue
                    val name = reply.optString("name").take(80).trim()
                    if (reply.optString("service") == "robot-eyes:1" && name.isNotEmpty() &&
                        name.none { it.isISOControl() }) {
                        remote.hostAddress?.let {
                            found[it] = mapOf("address" to it, "name" to name, "id" to reply.optString("id"))
                        }
                    }
                }
            }
        } catch (_: IOException) {
            return emptyList()
        }
        return found.values.toList()
    }

    fun pairDesktop(context: Context, address: String, code: String?): Boolean {
        if (!Regex("""\d{1,3}(?:\.\d{1,3}){3}""").matches(address)) return false
        val host = runCatching { InetAddress.getByName(address) }.getOrNull() as? Inet4Address ?: return false
        if (lanAddresses(context).none { sameSubnet(it.address, host, it.prefixLength) }) return false
        if (code == null && desktopAddress(context) != host) return false
        if (code != null && !Regex("""\d{8}""").matches(code)) return false
        val body = JSONObject().put("token", token(context)).put("phoneKey", publicKey(context))
            .put("phoneName", Build.MODEL)
            .apply { if (code != null) put("code", code) }
        val response = request(URL("http://$address:$DESKTOP_PORT/lan/pair"), body = body) ?: return false
        if (!response.optBoolean("ok")) return false
        val desktop = DesktopProfiles.remember(
            context, response.optString("desktopId"), response.optString("desktopName"),
            lan = address, select = code != null,
            lanKey = validKey(response.optString("lanKey")),
            tailHint = response.optString("tailscale").ifBlank { null },
            trustedKey = code != null,
        )
        if (DesktopProfiles.active(context)?.key != desktop.key) return false
        return connectDesktop(context)
    }

    private fun request(url: URL, authorization: String? = null, body: JSONObject? = null,
                        maxChars: Int = 1024): JSONObject? {
        val connection = url.openConnection(Proxy.NO_PROXY) as HttpURLConnection
        try {
            connection.connectTimeout = 2500
            connection.readTimeout = 2500
            connection.instanceFollowRedirects = false
            authorization?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val bytes = body.toString().toByteArray()
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            return connection.inputStream.bufferedReader().use { reader ->
                val chars = CharArray(maxChars + 1)
                var length = 0
                while (length < chars.size) {
                    val count = reader.read(chars, length, chars.size - length)
                    if (count < 0) break
                    length += count
                }
                if (length !in 1 until chars.size) null else JSONObject(String(chars, 0, length))
            }
        } catch (_: IOException) {
            return null
        } catch (_: org.json.JSONException) {
            return null
        } finally {
            connection.disconnect()
        }
    }

    fun config(context: Context, endpoint: String): String {
        val server = JSONObject().put("type", "http").put("url", endpoint)
            .put("headers", JSONObject().put("Authorization", "Bearer ${token(context)}"))
        return JSONObject().put("mcpServers", JSONObject().put("robot-eyes", server))
            .put("phoneKey", publicKey(context)).put("phoneName", Build.MODEL).toString(2)
    }

    fun publicKey(context: Context): String? = keys(context).getString("public", null)
    fun keySeed(context: Context): String? = keys(context).getString("seed", null)
    private fun keys(context: Context) = context.getSharedPreferences("lan_keys", Context.MODE_PRIVATE)

    @Synchronized
    fun saveKeys(context: Context, seed: String, public: String): String? {
        val current = keySeed(context)
        if (current != null) return current
        if (validKey(seed) == null || validKey(public) == null) return null
        keys(context).edit().putString("seed", seed).putString("public", public).apply()
        return seed
    }

    fun validKey(value: String): String? = value.takeIf { Regex("[A-Za-z0-9_-]{43}=").matches(it) }

    fun copyConfig(context: Context, endpoint: String) {
        val clip = ClipData.newPlainText("Robot Eyes MCP", config(context, endpoint))
        clip.description.extras = PersistableBundle().apply {
            putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    }

    fun allows(context: Context, local: InetAddress, remote: InetAddress): Boolean {
        if (local.isLoopbackAddress && remote.isLoopbackAddress) return true
        return lanAddresses(context).any { link ->
            link.address == local && remote is Inet4Address && sameSubnet(local, remote, link.prefixLength)
        }
    }

    @Synchronized
    fun receiveDesktopStatus(context: Context, source: InetAddress, snapshot: JSONObject): Boolean {
        val address = source.hostAddress ?: return false
        val key = snapshot.optString("desktopId")
        val selected = DesktopProfiles.active(context)
        if (key.isBlank() && selected != null &&
            (selected.lan != null || selected.key != "legacy") && selected.lan != address) return true
        val desktop = DesktopProfiles.remember(
            context, key, snapshot.optString("desktopName"), lan = address,
            lanKey = validKey(snapshot.optString("lanKey")),
        )
        if (DesktopProfiles.active(context)?.key != desktop.key) return true
        if (!publishDesktopStatus(snapshot)) return false
        if (snapshot.optInt("modelApi") == 1 && !source.isLoopbackAddress) {
            if (attemptedDesktop != desktop.key) {
                attemptedDesktop = desktop.key
                nextPairingAt = 0L
            }
            val now = SystemClock.elapsedRealtime()
            desktopSeenAt = now
            configSync = snapshot.optBoolean("configSync") && desktop.lanKey != null
            if ((verifiedDesktop != desktop.key || desktop.remote == null) &&
                !pairingInFlight && now >= nextPairingAt) {
                pairingInFlight = true
                nextPairingAt = now + 60_000L
                Thread({
                    try {
                        pairDesktop(context.applicationContext, address, null)
                    } finally {
                        synchronized(this) { pairingInFlight = false }
                    }
                }, "RearEyes-LanPairing").start()
            }
        }
        return true
    }

    @Synchronized
    fun desktopPairing(context: Context): String? {
        val address = desktopAddress(context) ?: return null
        return JSONObject().put("url", "http://${address.hostAddress}:$DESKTOP_PORT")
            .put("token", token(context)).put("lanKey", DesktopProfiles.active(context)?.lanKey).toString()
    }

    @Synchronized
    fun desktopReady(context: Context): Boolean {
        val seen = desktopSeenAt ?: return false
        return verifiedDesktop != null && verifiedDesktop == DesktopProfiles.active(context)?.key &&
            SystemClock.elapsedRealtime() - seen < 12_000L && desktopAddress(context) != null
    }

    @Synchronized
    fun settingsReady(context: Context): Boolean = configSync && desktopReady(context)

    fun connectDesktop(context: Context, syncTicket: String? = null): Boolean {
        val desktop = DesktopProfiles.active(context) ?: return false
        val address = desktopAddress(context) ?: return false
        val snapshot = request(URL("http://${address.hostAddress}:$DESKTOP_PORT/status"),
            authorization = token(context), maxChars = 16_384) ?: return false
        synchronized(this) {
            if (snapshot.optInt("modelApi") != 1 || DesktopProfiles.active(context) != desktop ||
                desktopAddress(context) != address ||
                (snapshot.optString("desktopId").isNotEmpty() && snapshot.optString("desktopId") != desktop.key) ||
                !publishDesktopStatus(snapshot, syncTicket ?: EyesBus.syncTicket)) return false
            desktopSeenAt = SystemClock.elapsedRealtime()
            verifiedDesktop = desktop.key
            configSync = snapshot.optBoolean("configSync") && desktop.lanKey != null
        }
        return true
    }

    fun desktopAddress(context: Context): InetAddress? {
        val address = DesktopProfiles.active(context)?.lan ?: return null
        // This value is recorded from an authenticated same-subnet socket.
        val host = runCatching { InetAddress.getByName(address) }.getOrNull() ?: return null
        return host.takeIf { remote ->
            remote is Inet4Address && lanAddresses(context).any { link ->
                sameSubnet(link.address, remote, link.prefixLength)
            }
        }
    }

    private fun publishDesktopStatus(snapshot: JSONObject, ticket: String = EyesBus.syncTicket): Boolean {
        val state = EyeState.entries.firstOrNull { it.name == snapshot.opt("state") } ?: return false
        fun usage(key: String): EyesBus.UsageWindow? {
            val used = snapshot.optInt(key, -1)
            val reset = snapshot.optLong(key + "Reset", -1L)
            return if (used in 0..100 && reset > 0) EyesBus.UsageWindow(used, reset) else null
        }
        EyesBus.setDesktopSnapshot(
            EyesBus.Transport.LAN, state, EyesBus.Usage(usage("five"), usage("week")), ticket,
            agents = EyesBus.readAgentStates(snapshot.optJSONObject("agents")),
            models = EyesBus.readModelConnections(snapshot.optJSONArray("models")),
        )
        return true
    }

    private fun sameSubnet(local: InetAddress, remote: InetAddress, prefix: Int): Boolean {
        if (prefix !in 1..32) return false
        val left = local.address
        val right = remote.address
        val fullBytes = prefix / 8
        if ((0 until fullBytes).any { left[it] != right[it] }) return false
        val bits = prefix % 8
        return bits == 0 || ((left[fullBytes].toInt() xor right[fullBytes].toInt()) and
            ((0xff shl (8 - bits)) and 0xff)) == 0
    }

    @Suppress("DEPRECATION")
    private fun lanAddresses(context: Context): List<LinkAddress> {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        return manager.allNetworks.flatMap { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true &&
                capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) != true) {
                emptyList()
            } else {
                manager.getLinkProperties(network)?.linkAddresses.orEmpty().filter {
                    it.address is Inet4Address && !it.address.isLoopbackAddress
                }
            }
        }
    }
}
