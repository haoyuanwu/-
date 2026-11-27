package com.reareyes.app

import android.content.Context
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder

/**
 * 极简 HTTP 服务（原生 ServerSocket，无依赖）。
 * GET /set?e=THINKING|QUESTION|DONE|ERROR|SLEEP|IDLE   切换表情
 * GET /usage                                           读取或更新用量
 * GET /ping                                            查询状态
 * GET /log                                             查看日志
 */
class EyesHttpServer(private val context: Context, private val port: Int) : Thread("EyesHttpServer") {

    @Volatile
    private var sock: ServerSocket? = null

    init {
        isDaemon = true
    }

    override fun run() {
        try {
            val ss = ServerSocket(port, 20, InetAddress.getByName("127.0.0.1"))
            sock = ss
            EyesBus.log("http listening on 127.0.0.1:$port")
            while (!isInterrupted) {
                val client = try {
                    ss.accept()
                } catch (e: Exception) {
                    break
                } ?: break
                try {
                    handle(client)
                } catch (e: Exception) {
                    EyesBus.log("http err: ${e.message}")
                }
            }
        } catch (e: Exception) {
            EyesBus.log("http server stopped: ${e.message}")
        }
    }

    private fun handle(client: Socket) {
        client.use { c ->
            c.soTimeout = 4000
            val reader = BufferedReader(InputStreamReader(c.getInputStream(), Charsets.UTF_8))
            val line = reader.readLine() ?: return
            val parts = line.split(" ")
            val method = parts.getOrNull(0) ?: "GET"
            val target = parts.getOrNull(1) ?: "/"
            val path = target.substringBefore('?')
            val query = if (target.contains('?')) target.substringAfter('?') else ""

            var status = "200 OK"
            val body: String = when {
                method != "GET" -> "GET only"
                path == "/set" -> {
                    val e = parseParams(query)["e"] ?: parseParams(query)["state"]
                    val st = EyeState.of(e)
                    EyesBus.set(st, "http")
                    "ok ${st.name}\n"
                }
                path == "/usage" -> {
                    if (query.isNotEmpty()) {
                        try {
                            val params = parseParams(query)
                            require(params.keys == setOf("five", "week", "fiveReset", "weekReset"))
                            EyesBus.updateUsage(EyesBus.Usage(
                                usageWindow(params.getValue("five"), params.getValue("fiveReset")),
                                usageWindow(params.getValue("week"), params.getValue("weekReset"))
                            ))
                        } catch (_: IllegalArgumentException) {
                            status = "400 Bad Request"
                        }
                    }
                    val usage = EyesBus.usage
                    val now = System.currentTimeMillis() / 1000L
                    "five=${usage.fiveHour?.activePercent(now) ?: "-"} week=${usage.week?.activePercent(now) ?: "-"}\n"
                }
                path == "/codex-sync" -> {
                    if (query.isEmpty()) {
                        "sync ${EyesBus.syncTicket}\n"
                    } else {
                        try {
                            val params = parseParams(query)
                            val state = params["state"]?.let(EyeState::valueOf)
                            val snapshot = EyesBus.Usage(
                                usageWindow(params.getValue("five"), params.getValue("fiveReset")),
                                usageWindow(params.getValue("week"), params.getValue("weekReset"))
                            )
                            val source = when (params["transport"]) {
                                "USB" -> EyesBus.Transport.USB
                                "LAN" -> EyesBus.Transport.LAN
                                else -> null
                            }
                            val agents = params["agents"]?.takeIf { it.length <= 8192 }?.let {
                                runCatching { EyesBus.readAgentStates(org.json.JSONObject(it)) }.getOrDefault(emptyMap())
                            }.orEmpty()
                            val models = params["models"]?.takeIf { it.length <= 8192 }?.let {
                                runCatching { EyesBus.readModelConnections(org.json.JSONArray(it)) }.getOrDefault(emptyList())
                            }.orEmpty()
                            val desktopId = params["desktopId"]
                            val active = DesktopProfiles.active(context)
                            val trusted = if (desktopId != null && source != null) {
                                val desktop = DesktopProfiles.remember(context, desktopId, params["desktopName"],
                                    lanKey = params["lanKey"]?.let(LanMcpSettings::validKey), trustedKey = true)
                                DesktopProfiles.active(context)?.key == desktop.key
                            } else {
                                active == null || active.key == "legacy" ||
                                    active.key.startsWith("remote:") || active.key.startsWith("lan:")
                            }
                            if (trusted) {
                                EyesBus.syncFromCodex(params.getValue("ticket"), state, snapshot, source, agents, models)
                            }
                            "ok sync\n"
                        } catch (_: IllegalArgumentException) {
                            status = "400 Bad Request"
                            "invalid snapshot\n"
                        } catch (_: NoSuchElementException) {
                            status = "400 Bad Request"
                            "incomplete snapshot\n"
                        }
                    }
                }
                path == "/calibrate" -> {
                    val open = EyesBus.onCalibrate
                    if (open == null) {
                        status = "409 Conflict"
                        "rear display is not active\n"
                    } else {
                        open()
                        "ok calibrate\n"
                    }
                }
                path == "/hello" -> {
                    EyesBus.greet()
                    "ok hello\n"
                }
                path == "/ping" -> "pong ${EyesBus.state.name}\n"
                path == "/log" -> EyesBus.dumpLog(60).joinToString("\n", postfix = "\n")
                else -> "Robot Eyes API: /set?e=THINKING|QUESTION|DONE|ERROR|SLEEP|IDLE  /ping  /log  /usage\n"
            }

            val bytes = body.toByteArray(Charsets.UTF_8)
            val out = c.getOutputStream()
            out.write(
                ("HTTP/1.1 $status\r\nContent-Type: text/plain; charset=utf-8\r\n" +
                    "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray()
            )
            out.write(bytes)
            out.flush()
        }
    }

    private fun usageWindow(percent: String, reset: String): EyesBus.UsageWindow? {
        if (percent == "-" && reset == "-") return null
        val used = percent.toInt()
        require(used in 0..100)
        val resetsAt = if (reset == "-") null else reset.toLong().also { require(it > 0L) }
        return EyesBus.UsageWindow(used, resetsAt)
    }

    private fun parseParams(query: String): Map<String, String> =
        query.split("&")
            .filter { it.contains("=") }
            .associate {
                val i = it.indexOf('=')
                it.substring(0, i) to URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }

    fun shutdown() {
        try {
            sock?.close()
        } catch (_: Exception) {
        }
    }
}
