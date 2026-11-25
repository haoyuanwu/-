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
        moveToRear(taskRoot)
        null
    } catch (error: Exception) {
        error.message ?: "背屏切换失败"
    }

    override fun launchRearDisplay(reuseVisibleTask: Boolean): String? = try {
        val existing = rearTasks()
        val canReuse = reuseVisibleTask && existing.any { it.display == 1 && it.visible }
        // HyperOS can leave the rear display's task stack asleep behind its wallpaper.
        wakeRear()
        if (!canReuse) {
            for (task in existing) removeRearTask(task)
            check(waitFor { rearTasks().isEmpty() }) { "旧背屏窗口尚未关闭，请重试" }
            // Start a fresh task on display 0, then move it just like the native activity.
            runCommand(
                "/system/bin/am", "start", "--user", "current", "--display", "0",
                "-f", "0x10010000", "-n", "com.reareyes.app/.MainActivity",
                "--ez", "com.reareyes.app.REAR_ONLY", "true",
            )
            val task = waitForRearTask(0)
            requireNotNull(task) { "找不到 Robot Eyes 的背屏窗口" }
            try {
                moveToRear(task.rootId)
                check(waitFor { rearTasks().any { it.id == task.id && it.display == 1 && it.visible } }) {
                    "系统没有把 Robot Eyes 移到背屏，请解锁手机后重试"
                }
            } catch (error: Exception) {
                runCatching { rearTasks().firstOrNull { it.id == task.id }?.let(::removeRearTask) }
                throw error
            }
        }
        null
    } catch (error: Exception) {
        error.message ?: "背屏切换失败"
    }

    private fun wakeRear() {
        runCommand("/system/bin/input", "-d", "1", "keyevent", "KEYCODE_WAKEUP")
    }

    private fun moveToRear(rootId: Int) {
        runCommand("/system/bin/am", "display", "move-stack", rootId.toString(), "1")
        wakeRear()
    }

    private fun removeRearTask(task: RearTask) {
        runCommand("/system/bin/am", "stack", "remove", task.id.toString())
    }

    private data class RearTask(val id: Int, val rootId: Int, val display: Int, val visible: Boolean)

    private fun waitFor(check: () -> Boolean): Boolean {
        repeat(8) {
            if (check()) return true
            Thread.sleep(150)
        }
        return false
    }

    private fun waitForRearTask(display: Int): RearTask? {
        var task: RearTask? = null
        waitFor {
            task = rearTasks().firstOrNull { it.display == display }
            task != null
        }
        return task
    }

    private fun rearTasks(): List<RearTask> = buildList {
        val stacks = runCommand("/system/bin/am", "stack", "list")
        var root: Pair<Int, Int>? = null
        for (line in stacks.lineSequence()) {
            if (line.startsWith("RootTask id=")) {
                val match = rearRoot.find(line)
                root = match?.let { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
            } else {
                val task = rearActivity.find(line) ?: continue
                val (rootId, display) = root ?: continue
                add(RearTask(task.groupValues[1].toInt(), rootId, display, visibleTask.containsMatchIn(line)))
            }
        }
    }

    private companion object {
        val rearRoot = Regex("""^RootTask id=(\d+) .*\bdisplayId=(\d+)\b""")
        val rearActivity = Regex("""^\s*taskId=(\d+): com\.reareyes\.app/(?:com\.reareyes\.app)?\.MainActivity\b""")
        val visibleTask = Regex("""\bvisible=true\b""")
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
