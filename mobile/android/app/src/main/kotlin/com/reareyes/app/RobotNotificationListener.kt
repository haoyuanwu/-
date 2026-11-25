package com.reareyes.app

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class RobotNotificationListener : NotificationListenerService() {
    private val seen = linkedMapOf<String, Map<String, Any>>()

    override fun onListenerConnected() {
        current = this
        activeNotifications.orEmpty().sortedBy { it.postTime }.takeLast(MAX_EVENTS).forEach {
            publish(it, initial = true)
        }
    }

    override fun onListenerDisconnected() {
        if (current === this) {
            current = null
            pending.clear()
        }
        seen.clear()
    }

    override fun onDestroy() {
        if (current === this) onListenerDisconnected()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (current === this) publish(sbn, initial = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        seen.remove(sbn.key)
        pending.remove(sbn.key)
    }

    private fun publish(sbn: StatusBarNotification, initial: Boolean) {
        if (sbn.packageName == packageName ||
            sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0 ||
            sbn.isOngoing || !isEnabled(this)
        ) return
        val content = content(sbn)
        if (content.title.isEmpty() && content.text.isEmpty() && !content.verification) return
        val event = mapOf(
            "type" to "notification",
            "id" to sbn.key,
            "package" to sbn.packageName,
            "app" to appLabel(sbn.packageName),
            "sender" to if (content.verification) "" else content.sender,
            "title" to if (content.verification) "收到验证消息" else content.title,
            "text" to if (content.verification) "" else content.text,
            "verification" to content.verification,
            "timestamp" to sbn.postTime,
        )
        if (seen[sbn.key] == event) return
        seen.remove(sbn.key)
        seen[sbn.key] = event
        if (seen.size > MAX_TRACKED) seen.remove(seen.keys.first())
        val payload = event + ("initial" to initial)
        val emit = onEvent
        if (emit != null) {
            emit(payload)
        } else {
            pending.remove(sbn.key)
            pending[sbn.key] = payload
            if (pending.size > MAX_EVENTS) pending.remove(pending.keys.first())
        }
    }

    @Suppress("DEPRECATION")
    private fun appLabel(id: String): String = try {
        val info = packageManager.getApplicationInfo(id, 0)
        packageManager.getApplicationLabel(info).toString().take(100)
    } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
        id
    }

    @Suppress("DEPRECATION")
    private fun content(sbn: StatusBarNotification): NotificationContent {
        val notification = sbn.notification
        val extras = notification.extras
        val message = extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.let {
            Notification.MessagingStyle.Message.getMessagesFromBundleArray(it).lastOrNull()
        }
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: message?.text)?.toString()?.trim().orEmpty()
        val messageSender = if (Build.VERSION.SDK_INT >= 28) message?.senderPerson?.name else message?.sender
        val sender = messageSender?.toString()?.trim()
            ?: title.takeIf { notification.category == Notification.CATEGORY_MESSAGE }.orEmpty()
        val verification = verificationPattern.containsMatchIn("$title $text $sender")
        return NotificationContent(title.take(200), text.take(1500), sender.take(200), verification)
    }

    private data class NotificationContent(
        val title: String,
        val text: String,
        val sender: String,
        val verification: Boolean,
    )

    companion object {
        private const val MAX_TRACKED = 128
        private const val MAX_EVENTS = 24
        private val verificationPattern = Regex(
            """验证码|驗證碼|校验码|認証コード|인증번호|동적\s*코드|""" +
                """\bOTP\b|one[- ]time (?:passcode|password|pin|code)|""" +
                "verification code|authentication code|security code|login code|" +
                """confirmation code|\b(?:\d[ -]?){4,8}\d?\s+is your\b""",
            RegexOption.IGNORE_CASE,
        )
        private val pending = linkedMapOf<String, Map<String, Any>>()
        private var current: RobotNotificationListener? = null
        var onEvent: ((Map<String, Any>) -> Unit)? = null

        fun isEnabled(context: Context): Boolean {
            val component = ComponentName(context, RobotNotificationListener::class.java)
            if (Build.VERSION.SDK_INT >= 27) {
                return context.getSystemService(NotificationManager::class.java)
                    .isNotificationListenerAccessGranted(component)
            }
            return Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
                ?.split(':')?.any { ComponentName.unflattenFromString(it) == component } == true
        }

        fun drain(context: Context): List<Map<String, Any>> {
            val entries = if (isEnabled(context)) pending.values.toList() else emptyList()
            pending.clear()
            return entries
        }

        fun details(context: Context, id: String): String? {
            val listener = current ?: return null
            if (!isEnabled(context) || id !in listener.seen) return null
            val active = listener.getActiveNotifications(arrayOf(id)).orEmpty().firstOrNull() ?: return null
            val content = listener.content(active)
            if (!content.verification) return null
            return listOf(content.title, content.text).filter(String::isNotEmpty).distinct()
                .joinToString("\n").takeIf(String::isNotEmpty)
        }
    }
}
