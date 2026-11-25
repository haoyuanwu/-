package com.reareyes.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ComponentName
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import rikka.shizuku.Shizuku

internal object RearDisplayBridge {
    private val handler = Handler(Looper.getMainLooper())
    private val args = Shizuku.UserServiceArgs(
        ComponentName("com.reareyes.app", RearDisplayService::class.java.name)
    ).processNameSuffix("rear_display").daemon(false).version(3)
    private var active: ServiceConnection? = null

    fun show(taskId: Int, onComplete: (String?) -> Unit) =
        execute({ it.showRearDisplay(taskId) }, onComplete)

    fun launch(onComplete: (String?) -> Unit) =
        execute({ it.launchRearDisplay() }, onComplete)

    private fun execute(
        action: (IRearDisplayService) -> String?,
        onComplete: (String?) -> Unit,
    ) {
        if (active != null) {
            onComplete("正在切换背屏，请稍候")
            return
        }
        val connection = object : ServiceConnection {
            private val timeout = Runnable { complete("连接 Shizuku 超时，请重试") }
            private var started = false

            fun bind() {
                active = this
                handler.postDelayed(timeout, 16000)
                try {
                    Shizuku.bindUserService(args, this)
                } catch (error: RuntimeException) {
                    complete(error.message ?: "无法连接 Shizuku")
                }
            }

            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (active !== this || started) return
                started = true
                Thread({
                    val error = try {
                        action(IRearDisplayService.Stub.asInterface(binder))
                    } catch (failure: Exception) {
                        failure.message ?: "Shizuku 已断开"
                    }
                    handler.post { complete(error) }
                }, "rear-display-switch").start()
            }

            override fun onServiceDisconnected(name: ComponentName) {
                complete("Shizuku 已断开，请重新启动后重试")
            }

            private fun complete(error: String?) {
                if (active !== this) return
                active = null
                handler.removeCallbacks(timeout)
                runCatching { Shizuku.unbindUserService(args, this, true) }
                onComplete(error)
            }
        }
        connection.bind()
    }
    fun offerShizuku(activity: Activity, message: String) {
        val launch = activity.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
        val dialog = AlertDialog.Builder(activity)
            .setTitle("背屏需要 Shizuku")
            .setMessage(message)
            .setNegativeButton("关闭", null)
        if (launch != null) dialog.setPositiveButton("打开 Shizuku") { _, _ -> activity.startActivity(launch) }
        dialog.show()
    }

}
