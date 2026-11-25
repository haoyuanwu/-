package com.reareyes.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.util.Base64

class UsbLanConfigProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        // Only the Android ADB shell may exchange pairing credentials.
        if (Binder.getCallingUid() != 2000) throw SecurityException("ADB shell required")
        val app = requireNotNull(context)
        if (method == "getLinkStatus") {
            val connected = EyesBus.Transport.TAILSCALE in EyesBus.connectedTransports() &&
                RemoteConnection.feedback.error == null
            return Bundle().apply { putBoolean("tailscale_connected", connected) }
        }
        if (method == "setRemotePairing") {
            val pairing = arg?.takeIf { it.length <= 1024 }?.let {
                runCatching { RemoteConnection.parse(it) }.getOrNull()
            } ?: return Bundle()
            RemoteConnection.saveFromUsb(app, pairing)
            return Bundle().apply { putBoolean("paired", true) }
        }
        require(method == "getConfig")
        if (!LanMcpSettings.enabled(app)) return Bundle()
        val endpoint = LanMcpSettings.endpoints(app).firstOrNull() ?: return Bundle()
        val config = LanMcpSettings.config(app, endpoint)
        return Bundle().apply {
            putString("lan_config", Base64.encodeToString(config.toByteArray(), Base64.NO_WRAP))
        }
    }

    override fun getType(uri: Uri): String? = null

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?,
    ) = 0
}
