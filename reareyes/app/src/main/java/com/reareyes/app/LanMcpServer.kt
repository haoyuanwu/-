package com.reareyes.app

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.Locale

/** Stateless MCP Streamable HTTP endpoint, kept on a separate port from local ADB routes. */
internal class LanMcpServer(private val context: Context) : Thread("LanMcpServer") {
    private val listener = ServerSocket()
    private val token = LanMcpSettings.token(context)
    private val agentName = Regex("[^\\p{Cntrl}]{1,80}")

    init {
        isDaemon = true
        try {
            listener.reuseAddress = true
            listener.bind(InetSocketAddress(InetAddress.getByName("0.0.0.0"), LanMcpSettings.PORT), 16)
        } catch (error: IOException) {
            listener.close()
            throw error
        }
    }

    override fun run() {
        while (!listener.isClosed) {
            val client = try {
                listener.accept()
            } catch (_: IOException) {
                break
            }
            client.use {
                try {
                    handle(it)
                } catch (_: IOException) {
                    // Client disconnected or exceeded the request deadline.
                }
            }
        }
    }

    fun shutdown() = listener.close()

    private fun handle(socket: Socket) {
        if (!LanMcpSettings.allows(context, socket.localAddress, socket.inetAddress)) {
            respond(socket, "403 Forbidden")
            return
        }
        socket.soTimeout = 2000
        val deadline = SystemClock.elapsedRealtime() + 2000
        val input = BufferedInputStream(socket.getInputStream())
        val request = readLine(input, deadline)?.split(' ') ?: return
        if (request.size != 3) return respond(socket, "400 Bad Request")
        val headers = mutableMapOf<String, String>()
        repeat(40) {
            val line = readLine(input, deadline) ?: return respond(socket, "400 Bad Request")
            if (line.isEmpty()) {
                handleRequest(socket, input, deadline, request[0], request[1], headers)
                return
            }
            val separator = line.indexOf(':')
            if (separator <= 0) return respond(socket, "400 Bad Request")
            val name = line.substring(0, separator).lowercase(Locale.ROOT)
            if (headers.put(name, line.substring(separator + 1).trim()) != null) {
                return respond(socket, "400 Bad Request")
            }
        }
        respond(socket, "431 Request Header Fields Too Large")
    }

    private fun handleRequest(socket: Socket, input: BufferedInputStream, deadline: Long,
                              method: String, target: String, headers: Map<String, String>) {
        if (target != "/mcp" && target != "/status-sync") return respond(socket, "404 Not Found")
        if (target == "/mcp" && !LanMcpSettings.enabled(context)) return respond(socket, "403 Forbidden")
        if (headers["origin"] != null) return respond(socket, "403 Forbidden")
        val expected = "Bearer $token".toByteArray()
        val actual = headers["authorization"].orEmpty().toByteArray()
        if (!MessageDigest.isEqual(expected, actual)) {
            return respond(socket, "401 Unauthorized", header = "WWW-Authenticate: Bearer\r\n")
        }
        if (method != "POST") {
            return respond(socket, "405 Method Not Allowed", header = "Allow: POST\r\n")
        }
        if (!headers["content-type"].orEmpty().substringBefore(';').trim().equals("application/json", true)) {
            return respond(socket, "415 Unsupported Media Type")
        }
        val version = headers["mcp-protocol-version"]
        if (version != null && version !in VERSIONS) return respond(socket, "400 Bad Request")
        if (headers.containsKey("transfer-encoding")) return respond(socket, "400 Bad Request")
        val length = headers["content-length"]?.toIntOrNull()
            ?: return respond(socket, "411 Length Required")
        if (length !in 1..16_384) return respond(socket, "413 Content Too Large")
        val bytes = ByteArray(length)
        var offset = 0
        while (offset < bytes.size) {
            if (SystemClock.elapsedRealtime() >= deadline) throw IOException("Request timeout")
            val count = input.read(bytes, offset, bytes.size - offset)
            if (count < 0) return respond(socket, "400 Bad Request")
            offset += count
        }
        val message = try {
            val parser = JSONTokener(bytes.toString(Charsets.UTF_8))
            val value = parser.nextValue()
            if (parser.nextClean() != '\u0000') throw JSONException("Trailing data")
            value
        } catch (_: JSONException) {
            return respond(socket, "400 Bad Request", error(JSONObject.NULL, -32700, "Parse error"))
        }
        if (message !is JSONObject) {
            return respond(socket, "400 Bad Request", error(JSONObject.NULL, -32600, "Invalid request"))
        }
        if (target == "/status-sync") {
            if (!LanMcpSettings.receiveDesktopStatus(context, socket.inetAddress, message)) {
                return respond(socket, "400 Bad Request")
            }
            val desktopId = message.optString("desktopId")
            val active = desktopId.isEmpty() || DesktopProfiles.active(context)?.key == desktopId
            return respond(socket, "200 OK", JSONObject().put("ok", true).put("active", active))
        }
        val id = message.opt("id")
        val rpcMethod = message.opt("method") as? String
        if (message.optString("jsonrpc") != "2.0" || rpcMethod == null ||
            (id != null && id !is String && id !is Number)) {
            return respond(socket, "400 Bad Request", error(JSONObject.NULL, -32600, "Invalid request"))
        }
        if (id == null) return respond(socket, "202 Accepted")
        val params = message.optJSONObject("params") ?: JSONObject()
        val result = when (rpcMethod) {
            "initialize" -> initialize(params)
            "ping" -> JSONObject()
            "tools/list" -> JSONObject().put("tools", JSONArray().put(stateTool()))
            "tools/call" -> {
                if (params.optString("name") != "set_eye_state") {
                    return respond(socket, "200 OK", error(id, -32602, "Unknown tool"))
                }
                setState(params.optJSONObject("arguments") ?: JSONObject())
            }
            else -> return respond(socket, "200 OK", error(id, -32601, "Method not found"))
        }
        respond(socket, "200 OK", envelope(id).put("result", result))
    }

    private fun initialize(params: JSONObject): JSONObject = JSONObject()
        .put("protocolVersion", params.optString("protocolVersion").takeIf { it in VERSIONS } ?: VERSIONS.first())
        .put("serverInfo", JSONObject().put("name", "robot-eyes").put("version", "1.0"))
        .put("capabilities", JSONObject().put("tools", JSONObject()))
        .put("instructions", "Call set_eye_state at task start, when waiting for approval, when resuming, and at task end. Use a consistent agent name and session ID per task.")

    private fun stateTool(): JSONObject {
        val properties = JSONObject()
            .put("agent", JSONObject().put("type", "string").put("description", "Stable agent name, e.g. WorkBuddy").put("maxLength", 80))
            .put("session", JSONObject().put("type", "string").put("description", "Optional session ID for concurrent tasks").put("maxLength", 80))
            .put("state", JSONObject().put("type", "string").put("enum", JSONArray(EyeState.entries.map { it.name })))
        return JSONObject().put("name", "set_eye_state")
            .put("description", "Update the Robot Eyes display. THINKING starts or resumes work, QUESTION waits for approval, DONE or ERROR ends work, and IDLE or SLEEP clears this session.")
            .put("inputSchema", JSONObject().put("type", "object").put("properties", properties)
                .put("required", JSONArray(listOf("agent", "state"))).put("additionalProperties", false))
    }

    private fun setState(args: JSONObject): JSONObject {
        val agent = (args.opt("agent") as? String)?.trim().orEmpty()
        val session = if (args.has("session")) (args.opt("session") as? String)?.trim().orEmpty() else "default"
        val state = EyeState.entries.firstOrNull { it.name == args.opt("state") }
        if (!agentName.matches(agent) || !agentName.matches(session) || state == null ||
            args.keys().asSequence().any { it !in setOf("agent", "session", "state") }) {
            return toolResult("Provide agent, a valid state, and optionally a session ID. Names must have 1–80 characters.", failed = true)
        }
        val display = synchronized(LanMcpSettings) {
            if (!LanMcpSettings.enabled(context)) return toolResult("LAN MCP is disabled.", failed = true)
            EyesBus.setAgentState(agent, session, state)
        }
            ?: return toolResult("Too many active sessions. Clear an existing session and retry.", failed = true)
        return toolResult("Reported ${state.name}; display is ${display.name}.")
    }

    private fun toolResult(message: String, failed: Boolean = false): JSONObject = JSONObject()
        .put("isError", failed)
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", message)))

    private fun envelope(id: Any): JSONObject = JSONObject().put("jsonrpc", "2.0").put("id", id)

    private fun error(id: Any, code: Int, message: String): JSONObject =
        envelope(id).put("error", JSONObject().put("code", code).put("message", message))

    private fun readLine(input: BufferedInputStream, deadline: Long): String? {
        val line = ByteArrayOutputStream()
        while (line.size() < 4096 && SystemClock.elapsedRealtime() < deadline) {
            val byte = input.read()
            if (byte < 0) return null
            if (byte == 10) return line.toString("ISO-8859-1").removeSuffix("\r")
            line.write(byte)
        }
        return null
    }

    private fun respond(socket: Socket, status: String, body: JSONObject? = null, header: String = "") {
        val content = body?.toString()?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val type = if (body == null) "" else "Content-Type: application/json\r\n"
        socket.getOutputStream().apply {
            write(("HTTP/1.1 $status\r\n${type}${header}Content-Length: ${content.size}\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
            write(content)
            flush()
        }
    }

    companion object {
        private val VERSIONS = listOf("2025-11-25", "2025-06-18", "2025-03-26")
    }
}
