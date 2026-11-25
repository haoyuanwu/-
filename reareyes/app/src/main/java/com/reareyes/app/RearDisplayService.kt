package com.reareyes.app

import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

/** Runs in Shizuku's shell process. Only the Robot Eyes task may be moved. */
class RearDisplayService : IRearDisplayService.Stub() {
    override fun destroy() = exitProcess(0)

    override fun showRearDisplay(taskId: Int): String? = try {
        val stacks = runCommand("/system/bin/am", "stack", "list")
        var taskRoot: Int? = null
        var currentRoot: Int? = null
        for (line in stacks.lineSequence()) {
            if (line.startsWith("RootTask id=")) {
                currentRoot = line.substringAfter("RootTask id=").substringBefore(' ').toIntOrNull()
            } else if (line.trimStart().startsWith("taskId=$taskId: com.reareyes.app/")) {
                taskRoot = currentRoot
                break
            }
        }
        requireNotNull(taskRoot) { "找不到 Robot Eyes 的窗口" }
        runCommand("/system/bin/am", "display", "move-stack", taskRoot.toString(), "1")
        runCommand("/system/bin/input", "-d", "1", "keyevent", "KEYCODE_WAKEUP")
        null
    } catch (error: Exception) {
        error.message ?: "背屏切换失败"
    }

    override fun launchRearDisplay(): String? = try {
        val existing = rearTask()
        if (existing?.display != 1 || !existing.visible) {
            // A hidden rear task can survive when the system takes the rear display back.
            if (existing?.display == 1) {
                runCommand("/system/bin/am", "stack", "remove", existing.id.toString())
            }
            if (existing == null || existing.display == 1) {
                // HyperOS rejects starting ordinary activities directly on display 1.
                runCommand(
                    "/system/bin/am", "start", "--user", "current", "--display", "0",
                    "-f", "0x10000000", "-n", "com.reareyes.app/.MainActivity",
                    "--ez", "com.reareyes.app.REAR_ONLY", "true",
                )
            }
            val task = existing?.takeIf { it.display == 0 } ?: waitForRearTask(0)
            requireNotNull(task) { "找不到 Robot Eyes 的背屏窗口" }
            runCommand("/system/bin/am", "display", "move-stack", task.id.toString(), "1")
        }
        runCommand("/system/bin/input", "-d", "1", "keyevent", "KEYCODE_WAKEUP")
        check(waitForRearTask(1, visible = true) != null) { "系统没有把 Robot Eyes 移到背屏，请解锁手机后重试" }
        null
    } catch (error: Exception) {
        error.message ?: "背屏切换失败"
    }

    private data class RearTask(val id: Int, val display: Int, val visible: Boolean)

    private fun waitForRearTask(display: Int, visible: Boolean = false): RearTask? {
        repeat(8) {
            val task = rearTask()
            if (task?.display == display && (!visible || task.visible)) return task
            Thread.sleep(150)
        }
        return null
    }

    private fun rearTask(): RearTask? {
        val stacks = runCommand("/system/bin/am", "stack", "list")
        var root: Pair<Int, Int>? = null
        for (line in stacks.lineSequence()) {
            if (line.startsWith("RootTask id=")) {
                val match = rearRoot.find(line)
                root = match?.let { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
            } else if (rearActivity.containsMatchIn(line)) {
                val (id, display) = root ?: continue
                return RearTask(id, display, line.contains(" visible=true "))
            }
        }
        return null
    }

    private companion object {
        val rearRoot = Regex("""^RootTask id=(\d+) .*\bdisplayId=(\d+)\b""")
        val rearActivity = Regex("""^\s*taskId=\d+: com\.reareyes\.app/(?:com\.reareyes\.app)?\.MainActivity\b""")
    }

    private fun runCommand(vararg command: String): String {
        val process = ProcessBuilder(*command).redirectErrorStream(true).start()
        val reader = FutureTask { process.inputStream.bufferedReader().use { it.readText() } }
        Thread(reader, "rear-display-command-output").start()
        try {
            check(process.waitFor(4, TimeUnit.SECONDS)) { "背屏操作超时" }
            val output = reader.get(1, TimeUnit.SECONDS)
            check(process.exitValue() == 0 && !output.trimStart().startsWith("Error:")) { output.trim() }
            return output
        } finally {
            if (process.isAlive) process.destroyForcibly()
            reader.cancel(true)
        }
    }
}
