package com.reareyes.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.NetworkCapabilities
import android.os.PersistableBundle
import java.net.Inet4Address
import java.net.InetAddress
import java.util.UUID
import org.json.JSONObject

internal object LanMcpSettings {
    const val PORT = 8789
    private const val PREFS = "lan_mcp"

    fun enabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getBoolean("enabled", true)

    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled).apply()
        if (!enabled) {
            EyesBus.clearAgentStates()
            EyesBus.clearDesktopSnapshot(EyesBus.Transport.LAN)
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

    fun config(context: Context, endpoint: String): String {
        val server = JSONObject().put("type", "http").put("url", endpoint)
            .put("headers", JSONObject().put("Authorization", "Bearer ${token(context)}"))
        return JSONObject().put("mcpServers", JSONObject().put("robot-eyes", server)).toString(2)
    }

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
