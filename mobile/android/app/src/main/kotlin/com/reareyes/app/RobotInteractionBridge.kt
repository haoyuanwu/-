package com.reareyes.app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.ContactsContract.Contacts
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

internal class RobotInteractionBridge(
    private val activity: FlutterHostActivity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "com.reareyes/interaction")
    private val events = EventChannel(messenger, "com.reareyes/interactionEvents")
    private val main = Handler(Looper.getMainLooper())
    private val settings = activity.getSharedPreferences(SETTINGS_PREFS, 0)
    private var sink: EventChannel.EventSink? = null
    private val receiveNotification: (Map<String, Any>) -> Unit = { sink?.success(it) }
    private var permissionResult: MethodChannel.Result? = null
    private var contactsPermissionResult: MethodChannel.Result? = null
    private val catalog = Executors.newSingleThreadExecutor()
    private var recognizer: SpeechRecognizer? = null
    private val localSpeech = if (
        activity.resources.configuration.locales[0]?.language == Locale.CHINESE.language
    ) LocalMandarinSpeech(activity.applicationContext, ::emit) else null
    private var engine: TextToSpeech? = null
    private var engineReady = false
    private var utterance: Utterance? = null
    private var closed = false

    private data class Utterance(val token: String, val id: String, val text: String)

    init {
        methods.setMethodCallHandler(::handle)
        events.setStreamHandler(this)
        localSpeech?.prepare()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(mapOf(
                "speech" to (localSpeech != null || SpeechRecognizer.isRecognitionAvailable(activity)),
                "notifications" to true,
                "liveActivity" to false,
            ))
            "notificationAccess" -> result.success(RobotNotificationListener.isEnabled(activity))
            "openNotificationSettings" -> try {
                activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                result.success(null)
            } catch (_: ActivityNotFoundException) {
                result.error("notification_settings", "无法打开通知使用权设置。", null)
            }
            "pendingEvents" -> result.success(RobotNotificationListener.drain(activity))
            "notificationApps" -> readCatalog(result, ::launchableApps)
            "notificationAppIcon" -> {
                val packageName = call.arguments as? String
                catalog.execute {
                    val icon = packageName?.let { appIconBytes(activity, it) }
                    main.post { if (!closed) result.success(icon) }
                }
            }
            "openNoticeApp" -> result.success(openNoticeApp(call))
            "openNoticeOverlaySettings" -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.fromParts("package", activity.packageName, null),
                )
                result.success(runCatching { activity.startActivity(intent) }.isSuccess)
            }
            "notificationContacts" -> requestContacts(result)
            "notificationDetails" -> {
                val id = call.arguments as? String ?: call.argument<String>("id")
                result.success(id?.let { RobotNotificationListener.details(activity, it) })
            }
            "loadRecentNotices" -> result.success(settings.getString("recentNotices", null))
            "saveRecentNotices" -> {
                val json = call.arguments as? String
                if (json == null || json.toByteArray(Charsets.UTF_8).size > 160_000) {
                    result.error("notice_history", "提醒记录超过大小限制。", null)
                } else {
                    settings.edit().putString("recentNotices", json).apply()
                    result.success(null)
                }
            }
            "loadSettings" -> result.success(settings.getString(SETTINGS_KEY, null))
            "saveSettings" -> {
                val json = call.arguments as? String
                if (json == null || json.length > 256 * 1024) {
                    result.error("interaction_settings", "无效的语音和通知设置。", null)
                } else {
                    settings.edit().putString(SETTINGS_KEY, json).apply()
                    result.success(null)
                }
            }
            "startListening" -> requestListening(result)
            "stopListening" -> {
                localSpeech?.stop()
                recognizer?.stopListening()
                result.success(null)
            }
            "cancelListening" -> {
                val pendingPermission = permissionResult
                permissionResult = null
                pendingPermission?.success(null)
                suspendListening()
                result.success(null)
            }
            "speak" -> {
                val text = call.argument<String>("text")?.trim()
                if (text.isNullOrEmpty() || text.length > TextToSpeech.getMaxSpeechInputLength()) {
                    result.error("speech_text", "朗读内容为空或过长。", null)
                    return
                }
                speak(text, call.argument<String>("id"))
                result.success(null)
            }
            "stopSpeaking" -> {
                stopSpeaking()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        RobotNotificationListener.onEvent = receiveNotification
    }

    override fun onCancel(arguments: Any?) {
        if (RobotNotificationListener.onEvent === receiveNotification) {
            RobotNotificationListener.onEvent = null
        }
        sink = null
    }

    private fun emit(type: String, fields: Map<String, Any> = emptyMap()) {
        sink?.success(fields + ("type" to type))
    }

    private fun requestListening(result: MethodChannel.Result) {
        if (localSpeech == null && !SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.error("speech_unavailable", "这台设备未提供语音识别服务。", null)
        } else if (permissionResult != null || recognizer != null || localSpeech?.active == true) {
            result.error("speech_busy", "麦克风正在使用。", null)
        } else if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startListening(result)
        } else {
            permissionResult = result
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_PERMISSION)
        }
    }

    fun onPermissionsResult(request: Int, grantResults: IntArray) {
        if (request == CONTACTS_PERMISSION) {
            val result = contactsPermissionResult ?: return
            contactsPermissionResult = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                readCatalog(result, ::contacts)
            } else {
                result.error("contacts_permission", "请在系统设置中允许访问联系人。", null)
            }
            return
        }
        if (request != MICROPHONE_PERMISSION) return
        val result = permissionResult ?: return
        permissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startListening(result)
        } else {
            result.error("microphone_permission", "请允许 Robot Eyes 使用麦克风。", null)
        }
    }

    private fun requestContacts(result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) {
            readCatalog(result, ::contacts)
        } else if (contactsPermissionResult == null) {
            contactsPermissionResult = result
            activity.requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), CONTACTS_PERMISSION)
        } else {
            result.error("contacts_permission", "联系人授权正在进行。", null)
        }
    }

    private fun readCatalog(result: MethodChannel.Result, load: () -> List<Map<String, Any>>) {
        catalog.execute {
            try {
                val entries = load()
                main.post { if (!closed) result.success(entries) }
            } catch (_: RuntimeException) {
                main.post { if (!closed) result.error("catalog", "无法读取列表，请重试。", null) }
            }
        }
    }

    private fun openNoticeApp(call: MethodCall): String {
        val source = call.argument<String>("package")
        if (source.isNullOrBlank() || source == activity.packageName) return "unavailable"
        val id = call.argument<String>("id")
        val launch = activity.packageManager.getLaunchIntentForPackage(source)
        val target = id?.let {
            runCatching { RobotNotificationListener.openIntent(activity, it, source) }.getOrNull()
        }
        if (target == null && launch == null) return "unavailable"
        val withShortcut = call.argument<Boolean>("withShortcut") != false
        if (withShortcut && !Settings.canDrawOverlays(activity)) return "permission"
        if (withShortcut) activity.noticeReturnShortcut.show()
        val opened = (target != null && runCatching { target.send() }.isSuccess) ||
            (launch != null && runCatching { activity.startActivity(launch) }.isSuccess)
        if (!opened) activity.noticeReturnShortcut.dismiss()
        return if (opened) "opened" else "unavailable"
    }

    @Suppress("DEPRECATION")
    private fun launchableApps(): List<Map<String, Any>> {
        val manager = activity.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return manager.queryIntentActivities(launcher, 0)
            .map { it.activityInfo }
            .filter { it.exported && it.packageName != activity.packageName }
            .distinctBy { it.packageName }
            .map { mapOf("id" to it.packageName, "name" to manager.getApplicationLabel(it.applicationInfo).toString()) }
    }

    private fun contacts(): List<Map<String, Any>> {
        val resolver = activity.contentResolver
        val numbers = mutableMapOf<String, MutableSet<String>>()
        resolver.query(Phone.CONTENT_URI, arrayOf(Phone.CONTACT_ID, Phone.NUMBER, Phone.NORMALIZED_NUMBER), null, null, null)
            ?.use { cursor ->
                while (cursor.moveToNext()) {
                    val alternatives = numbers.getOrPut(cursor.getString(0)) { linkedSetOf() }
                    cursor.getString(1)?.let(alternatives::add)
                    cursor.getString(2)?.let(alternatives::add)
                }
            }
        val entries = mutableListOf<Map<String, Any>>()
        resolver.query(Contacts.CONTENT_URI, arrayOf(Contacts._ID, Contacts.LOOKUP_KEY, Contacts.DISPLAY_NAME_PRIMARY), null, null, null)
            ?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val aliases = numbers[id].orEmpty()
                    val name = cursor.getString(2)?.takeIf(String::isNotBlank) ?: aliases.firstOrNull() ?: continue
                    entries += mapOf("id" to (cursor.getString(1) ?: id), "name" to name, "aliases" to aliases.toList())
                }
            }
        return entries
    }

    private fun startListening(result: MethodChannel.Result) {
        stopSpeaking()
        if (localSpeech != null) {
            localSpeech.start(result)
            return
        }
        try {
            val session = SpeechRecognizer.createSpeechRecognizer(activity)
            recognizer = session
            session.setRecognitionListener(object : RecognitionListener {
                private var lastLevelAt = 0L
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() {
                    if (recognizer === session) emit("speechDetected")
                }
                override fun onRmsChanged(rmsdB: Float) {
                    if (recognizer !== session || !rmsdB.isFinite()) return
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now - lastLevelAt < 65L) return
                    lastLevelAt = now
                    val level = ((rmsdB - 1f) / 12f).coerceIn(0f, 1f)
                    emit("speechLevel", mapOf("level" to level.toDouble()))
                }
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit

                override fun onPartialResults(partialResults: Bundle?) {
                    if (recognizer === session) emitTranscript(partialResults, final = false)
                }

                override fun onResults(results: Bundle?) {
                    if (recognizer !== session) return
                    emitTranscript(results, final = true)
                    finishListening(session)
                }

                override fun onError(error: Int) {
                    if (recognizer !== session) return
                    val description = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                            "没有听清，请再试一次。"
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "麦克风权限不可用。"
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                            "语音识别服务连接失败。"
                        else -> "语音识别暂时不可用。"
                    }
                    emit("speechError", mapOf("text" to description))
                    finishListening(session)
                }
            })
            session.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            })
            result.success(null)
        } catch (_: RuntimeException) {
            suspendListening()
            result.error("speech_start", "无法启动语音识别。", null)
        }
    }

    private fun emitTranscript(result: Bundle?, final: Boolean) {
        val text = result?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()?.trim()
        if (!text.isNullOrEmpty()) emit("speech", mapOf("text" to text, "final" to final))
    }

    private fun finishListening(session: SpeechRecognizer) {
        recognizer = null
        session.destroy()
        emit("speechEnd")
    }

    fun suspendListening() {
        if (localSpeech?.active == true) {
            localSpeech.cancel()
            emit("speechEnd")
        }
        val session = recognizer ?: return
        recognizer = null
        session.cancel()
        session.destroy()
        emit("speechEnd")
    }

    private fun speak(text: String, id: String?) {
        val token = UUID.randomUUID().toString()
        utterance = Utterance(token, id ?: token, text)
        if (engineReady) {
            playUtterance()
        } else if (engine == null) {
            engine = TextToSpeech(activity.applicationContext) { status ->
                main.post { configureEngine(status) }
            }
        }
    }

    private fun configureEngine(status: Int) {
        val speech = engine ?: return
        if (closed) return
        if (status != TextToSpeech.SUCCESS) {
            speech.shutdown()
            engine = null
            finishUtterance(utterance?.token, "设备未提供可用的朗读引擎。")
            return
        }
        speech.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                main.post {
                    val item = utterance?.takeIf { it.token == utteranceId } ?: return@post
                    emit("speechStarted", mapOf("id" to item.id))
                }
            }
            override fun onDone(utteranceId: String?) {
                main.post { finishUtterance(utteranceId) }
            }
            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                main.post { finishUtterance(utteranceId) }
            }
            @Deprecated("Android TTS callback")
            override fun onError(utteranceId: String?) {
                main.post { finishUtterance(utteranceId, "语音朗读失败。") }
            }
        })
        engineReady = true
        playUtterance()
    }

    private fun playUtterance() {
        val item = utterance ?: return
        val speech = engine ?: return
        val current = speech.voice
        if (current == null || current.isNetworkConnectionRequired) {
            val language = current?.locale?.language ?: Locale.getDefault().language
            val localVoice = speech.voices.orEmpty().firstOrNull {
                !it.isNetworkConnectionRequired && it.locale.language == language
            }
            if (localVoice == null || speech.setVoice(localVoice) != TextToSpeech.SUCCESS) {
                finishUtterance(item.token, "设备未安装可用的离线朗读音色。")
                return
            }
        }
        if (speech.speak(item.text, TextToSpeech.QUEUE_FLUSH, null, item.token) != TextToSpeech.SUCCESS) {
            finishUtterance(item.token, "语音朗读失败。")
        }
    }

    private fun finishUtterance(token: String?, error: String? = null) {
        val item = utterance?.takeIf { it.token == token } ?: return
        utterance = null
        val fields = mutableMapOf("id" to item.id, "text" to item.text)
        if (error != null) fields["error"] = error
        emit("speechDone", fields)
    }

    private fun stopSpeaking() {
        utterance = null
        engine?.stop()
    }

    fun close() {
        catalog.shutdownNow()
        contactsPermissionResult?.error("closed", "联系人选择已关闭。", null)
        contactsPermissionResult = null
        closed = true
        onCancel(null)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        permissionResult?.error("interaction_closed", "语音界面已关闭。", null)
        permissionResult = null
        suspendListening()
        localSpeech?.close()
        stopSpeaking()
        engine?.shutdown()
        engine = null
    }

    companion object {
        @Suppress("DEPRECATION")
        internal fun appLogo(context: Context, packageName: String): Drawable? =
            runCatching {
                val manager = context.packageManager
                val info = manager.getApplicationInfo(packageName, 0)
                if (info.icon == 0) null else manager.getApplicationIcon(info)
            }.getOrNull()

        internal fun appIconBytes(context: Context, packageName: String): ByteArray? {
            return try {
                val drawable = appLogo(context, packageName) ?: return null
                val bitmap = Bitmap.createBitmap(72, 72, Bitmap.Config.ARGB_8888)
                try {
                    drawable.setBounds(0, 0, bitmap.width, bitmap.height)
                    drawable.draw(Canvas(bitmap))
                    ByteArrayOutputStream().use { output ->
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                        output.toByteArray()
                    }
                } finally {
                    bitmap.recycle()
                }
            } catch (_: RuntimeException) {
                null
            }
        }

        private const val MICROPHONE_PERMISSION = 3
        private const val CONTACTS_PERMISSION = 4
        const val SETTINGS_PREFS = "interaction"
        const val SETTINGS_KEY = "preferences"
    }
}
