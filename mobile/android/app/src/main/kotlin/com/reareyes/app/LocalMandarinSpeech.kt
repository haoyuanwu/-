package com.reareyes.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream
import kotlin.math.sqrt

/** Owns the microphone and Mandarin recognizer for the current Android voice session. */
internal class LocalMandarinSpeech(
    private val context: Context,
    private val emit: (String, Map<String, Any>) -> Unit,
) {
    private class Recording(var reply: MethodChannel.Result?) {
        @Volatile var stopped = false
        @Volatile var cancelled = false
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var model: Model? = null // Worker thread only.
    private var recording: Recording? = null // Main thread only.
    val active: Boolean get() = recording != null

    fun prepare() {
        worker.execute { runCatching { openModel() } }
    }

    fun start(reply: MethodChannel.Result) {
        val session = Recording(reply)
        recording = session
        worker.execute {
            try {
                recognize(session)
            } catch (_: SecurityException) {
                reportFailure(session, "无法使用麦克风，请检查录音权限。")
            } catch (_: Exception) {
                reportFailure(session, "本机语音识别暂时无法启动，请重试。")
            } catch (_: LinkageError) {
                reportFailure(session, "当前设备无法运行本机语音识别。")
            }
        }
    }

    fun stop() {
        recording?.stopped = true
    }

    fun cancel() {
        val session = recording ?: return
        recording = null
        session.cancelled = true
        session.stopped = true
        session.reply?.success(null)
        session.reply = null
    }

    fun close() {
        cancel()
        worker.execute {
            model?.close()
            model = null
        }
        worker.shutdown()
    }

    @SuppressLint("MissingPermission") // The bridge checks permission before starting.
    private fun recognize(session: Recording) {
        val languageModel = openModel()
        if (session.stopped) return
        val minimum = AudioRecord.getMinBufferSize(RATE, CHANNEL, ENCODING)
        check(minimum > 0)
        val audio = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,
            RATE, CHANNEL, ENCODING, maxOf(minimum, CHUNK * 4))
        try {
            check(audio.state == AudioRecord.STATE_INITIALIZED)
            Recognizer(languageModel, RATE.toFloat()).use { decoder ->
                if (session.stopped) return
                audio.startRecording()
                check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING)
                deliver(session) {
                    session.reply?.success(null)
                    session.reply = null
                }
                val samples = ShortArray(CHUNK)
                val segments = StringBuilder()
                var lastPartial = ""
                var captured = 0
                var lastVoice = 0
                while (!session.stopped && captured < RATE * MAX_SECONDS) {
                    val count = audio.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                    check(count > 0)
                    captured += count
                    if (session.cancelled) return
                    val squareSum = (0 until count).sumOf { index ->
                        val sample = samples[index] / 32768.0
                        sample * sample
                    }
                    val rms = sqrt(squareSum / count)
                    val level = ((rms - 0.005) / 0.065).coerceIn(0.0, 1.0)
                    if (rms >= 0.012) lastVoice = captured
                    deliver(session) { emit("speechLevel", mapOf("level" to level)) }
                    val partial = if (decoder.acceptWaveForm(samples, count)) {
                        segments.append(transcript(decoder.result, "text"))
                        segments.toString()
                    } else {
                        segments.toString() + transcript(decoder.partialResult, "partial")
                    }
                    if (partial.isNotEmpty() && partial != lastPartial) {
                        lastPartial = partial
                        deliver(session) { emit("speech", mapOf("text" to partial, "final" to false)) }
                    }
                    if ((lastPartial.isNotEmpty() && captured - lastVoice >= RATE * 17 / 10) ||
                        (lastVoice == 0 && captured >= RATE * 8)
                    ) break
                }
                if (!session.cancelled) {
                    val text = segments.append(transcript(decoder.finalResult, "text")).toString()
                        .ifEmpty { lastPartial }
                    deliver(session) {
                        recording = null
                        if (text.isNotEmpty()) {
                            emit("speech", mapOf("text" to text, "final" to true))
                            emit("speechEnd", emptyMap())
                        } else {
                            emit("speechError", mapOf("text" to "没有听清，请再试一次。"))
                        }
                    }
                }
            }
        } finally {
            try {
                if (audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) audio.stop()
            } finally {
                audio.release()
            }
        }
    }

    private fun deliver(session: Recording, callback: () -> Unit) {
        main.post { if (recording === session) callback() }
    }

    private fun reportFailure(session: Recording, message: String) {
        deliver(session) {
            recording = null
            val reply = session.reply
            session.reply = null
            if (reply != null) reply.error("local_speech", message, null)
            else emit("speechError", mapOf("text" to message))
        }
    }

    private fun transcript(json: String, key: String): String =
        JSONObject(json).optString(key).replace(" ", "")

    private fun openModel(): Model {
        model?.let { return it }
        val destination = File(context.noBackupFilesDir, MODEL)
        if (!destination.isDirectory) {
            val temporary = Files.createTempDirectory(context.noBackupFilesDir.toPath(), "speech-").toFile()
            try {
                val root = temporary.canonicalPath + File.separator
                ZipInputStream(context.assets.open("$MODEL.zip")).use { archive ->
                    while (true) {
                        val entry = archive.nextEntry ?: break
                        val output = File(temporary, entry.name)
                        check(output.canonicalPath.startsWith(root))
                        if (entry.isDirectory) {
                            output.mkdirs()
                        } else {
                            output.parentFile?.mkdirs()
                            output.outputStream().use { archive.copyTo(it) }
                        }
                        archive.closeEntry()
                    }
                }
                Files.move(File(temporary, MODEL).toPath(), destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE)
            } finally {
                temporary.deleteRecursively()
            }
        }
        return Model(destination.path).also { model = it }
    }

    private companion object {
        const val MODEL = "vosk-model-small-cn-0.22"
        const val RATE = 16_000
        const val CHUNK = 1_600
        const val MAX_SECONDS = 30
        const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
    }
}
