package com.reareyes.app

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

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
    }

    private fun publish(sbn: StatusBarNotification, initial: Boolean) {
        if (sbn.packageName == packageName ||
            sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0 ||
            sbn.isOngoing || !isEnabled(this)
        ) return
        val content = content(sbn)
        val event = mapOf(
            "type" to "notification",
            "id" to sbn.key,
            "package" to sbn.packageName,
            "app" to appLabel(sbn.packageName),
            "sender" to if (content.verification) "" else content.sender,
            "title" to if (content.verification) "收到验证消息" else content.title.ifBlank { "新提醒" },
            "text" to if (content.verification) "" else content.text,
            "verification" to content.verification,
            "timestamp" to sbn.postTime,
        )
        if (seen[sbn.key] == event) return
        seen.remove(sbn.key)
        seen[sbn.key] = event
        if (seen.size > MAX_TRACKED) seen.remove(seen.keys.first())
        val recent = System.currentTimeMillis() - sbn.postTime in 0L..12_000L
        if ((!initial || recent) && matchesRearRules(sbn.packageName, if (content.verification)
                content.copy(sender = "", title = "收到验证消息", text = "") else content)) {
            EyesBus.showRearNotice(
                EyesBus.RearNotice(
                    key = "${sbn.key}:${sbn.postTime}",
                    source = event.getValue("app").toString(),
                    title = event.getValue("title").toString(),
                    text = event.getValue("text").toString(),
                    icon = RobotInteractionBridge.appLogo(this, sbn.packageName),
                    startedAt = SystemClock.elapsedRealtime(),
                    react = !initial,
                ),
            )
        }
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

    private fun matchesRearRules(packageName: String, notice: NotificationContent): Boolean {
        val raw = getSharedPreferences(RobotInteractionBridge.SETTINGS_PREFS, MODE_PRIVATE)
            .getString(RobotInteractionBridge.SETTINGS_KEY, null) ?: return true
        val settings = runCatching { JSONObject(raw) }.getOrNull() ?: return false
        val sources = settings.optJSONObject("sources")
        if (sources?.has(packageName) == true) return true
        val keywords = settings.optJSONArray("keywords")
        val contacts = settings.optJSONArray("contacts")
        val words = if (keywords == null) settings.optString("filter")
            .split(',', '，', '\n').map(String::trim).filter(String::isNotEmpty)
        else (0 until keywords.length()).mapNotNull { keywords.opt(it) as? String }
        if (words.isEmpty() && (contacts?.length() ?: 0) == 0) return (sources?.length() ?: 0) == 0
        val content = "${notice.sender} ${notice.title} ${notice.text}"
        if (words.any { it.isNotBlank() && content.contains(it, ignoreCase = true) }) return true
        val sender = notice.sender.trim()
        if (sender.isEmpty() || contacts == null) return false
        val number = sender.filter(Char::isDigit).takeIf {
            it.length >= 7 && sender.matches(Regex("""\+?[\d ()-]+"""))
        }
        for (i in 0 until contacts.length()) {
            val contact = contacts.optJSONObject(i) ?: continue
            if (contact.optString("name").trim().equals(sender, ignoreCase = true)) return true
            val aliases = contact.optJSONArray("aliases") ?: continue
            if (number != null && (0 until aliases.length()).any {
                    aliases.optString(it).filter(Char::isDigit) == number
                }) return true
        }
        return false
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
        private var lastRebind: Long? = null
        var onEvent: ((Map<String, Any>) -> Unit)? = null

        fun isConnected(): Boolean = current != null

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
            if (!isEnabled(context)) {
                pending.clear()
                return emptyList()
            }
            val now = SystemClock.elapsedRealtime()
            if (current == null && (lastRebind?.let { now - it >= 5_000L } != false)) {
                lastRebind = now
                runCatching {
                    requestRebind(ComponentName(context, RobotNotificationListener::class.java))
                }
            }
            return pending.values.toList().also { pending.clear() }
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
