package com.reareyes.app

import android.content.Context
import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

internal object DesktopProfiles {
    data class Desktop(
        val key: String,
        val name: String,
        val lan: String?,
        val remote: RemoteConnection.Pairing?,
        val lanKey: String? = null,
        val tailHint: String? = null,
    )

    private fun prefs(context: Context) = context.getSharedPreferences("desktop_profiles", Context.MODE_PRIVATE)

    private fun load(context: Context): MutableList<Desktop> {
        val source = prefs(context).getString("entries", null)
        if (source == null) {
            val remote = RemoteConnection.load(context)
            val lan = context.getSharedPreferences("lan_mcp", Context.MODE_PRIVATE).getString("desktop", null)
            if (remote == null && lan == null) return mutableListOf()
            val first = Desktop(remote?.desktopId ?: "legacy", remote?.desktopName ?: fallbackName(remote, lan),
                lan, remote)
            store(context, listOf(first), first.key)
            return mutableListOf(first)
        }
        val rows = JSONArray(source)
        return MutableList(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            Desktop(row.getString("key"), row.getString("name"), row.optString("lan").ifBlank { null },
                row.optJSONObject("remote")?.let { RemoteConnection.parse(it.toString()) },
                row.optString("lanKey").ifBlank { null }, row.optString("tailHint").ifBlank { null })
        }
    }

    private fun store(context: Context, list: List<Desktop>, active: String?) {
        val rows = JSONArray()
        for (entry in list) {
            rows.put(JSONObject().put("key", entry.key).put("name", entry.name)
                .put("lan", entry.lan).put("remote", entry.remote?.let(RemoteConnection::json))
                .put("lanKey", entry.lanKey).put("tailHint", entry.tailHint))
        }
        prefs(context).edit().putString("entries", rows.toString()).putString("active", active).apply()
    }

    private fun fallbackName(remote: RemoteConnection.Pairing?, lan: String?) =
        remote?.url?.let { URI(it).host?.substringBefore('.') } ?: lan ?: "电脑"
    private fun nameKey(label: String) = label.lowercase().removeSuffix(".local")

    @Synchronized
    fun active(context: Context): Desktop? {
        val list = load(context)
        val key = prefs(context).getString("active", null)
        return list.firstOrNull { it.key == key }
    }

    @Synchronized
    fun list(context: Context): List<Map<String, Any?>> {
        val rows = load(context)
        val selected = prefs(context).getString("active", null)
        return rows.map { entry ->
            mapOf("key" to entry.key, "name" to entry.name, "lan" to entry.lan,
                "tailscale" to entry.remote?.url, "active" to (entry.key == selected))
        }
    }

    @Synchronized
    fun remember(
        context: Context, id: String?, name: String?, lan: String? = null,
        remote: RemoteConnection.Pairing? = null, select: Boolean = false,
        lanKey: String? = null, tailHint: String? = null, trustedKey: Boolean = false,
    ): Desktop {
        val rows = load(context)
        val active = prefs(context).getString("active", null)
        val identity = id?.takeIf { Regex("[a-f0-9]{24}").matches(it) }
        val label = name?.trim()?.takeIf { it.isNotEmpty() && it.length <= 80 && it.none(Char::isISOControl) }
        val retired = prefs(context).getStringSet("retired", emptySet()).orEmpty().toMutableSet()
        if (!select && identity in retired) {
            return Desktop(identity!!, label ?: fallbackName(remote, lan), lan, remote)
        }
        val matching = rows.filter { item ->
            (identity != null && item.key == identity) ||
                (label != null && nameKey(item.name) == nameKey(label)) ||
                (remote != null && item.remote?.url == remote.url) ||
                (lan != null && item.lan == lan && (item.key == "legacy" || item.key.startsWith("lan:")))
        }
        val old = matching.firstOrNull { it.key == identity }
            ?: matching.firstOrNull { it.key == active } ?: matching.firstOrNull()
        val entry = Desktop(
            identity ?: old?.key ?: (remote?.let { "remote:${it.url}" } ?: "lan:$lan"),
            label ?: old?.name ?: fallbackName(remote, lan),
            lan ?: old?.lan ?: matching.firstNotNullOfOrNull { it.lan },
            remote ?: old?.remote ?: matching.firstNotNullOfOrNull { it.remote },
            if (trustedKey || old?.lanKey == null) lanKey ?: old?.lanKey else old.lanKey,
            tailHint ?: old?.tailHint,
        )
        val changed = entry != old || matching.size > 1
        if (changed) {
            val index = rows.indexOf(old)
            rows.removeAll(matching.toSet())
            rows.add(if (index < 0) rows.size else minOf(index, rows.size), entry)
            for (entryBefore in matching) {
                if (entryBefore.key != entry.key && Regex("[a-f0-9]{24}").matches(entryBefore.key)) {
                    retired.add(entryBefore.key)
                }
            }
            retired.remove(identity)
            prefs(context).edit().putStringSet("retired", retired).apply()
        }
        val next = if (select || active == null || matching.any { it.key == active }) entry.key else active
        if (changed || next != active) store(context, rows, next)
        if (next == entry.key) {
            if (active != null && (active != next || (old != null && old.lan != entry.lan))) clearLocalStatus()
            if (RemoteConnection.load(context) != entry.remote) RemoteConnection.save(context, entry.remote)
        }
        return entry
    }

    @Synchronized
    fun select(context: Context, key: String): Boolean {
        val rows = load(context)
        val desktop = rows.firstOrNull { it.key == key } ?: return false
        if (prefs(context).getString("active", null) == key) return true
        store(context, rows, key)
        clearLocalStatus()
        RemoteConnection.save(context, desktop.remote)
        return true
    }

    @Synchronized
    fun clearRemote(context: Context) {
        val active = active(context) ?: return
        val rows = load(context)
        store(context, rows.map { if (it.key == active.key) it.copy(remote = null) else it }, active.key)
        RemoteConnection.save(context, null)
    }

    private fun clearLocalStatus() {
        EyesBus.clearDesktopSnapshot(EyesBus.Transport.USB)
        EyesBus.clearDesktopSnapshot(EyesBus.Transport.LAN)
        EyesBus.refreshDesktopStatus()
    }
}
