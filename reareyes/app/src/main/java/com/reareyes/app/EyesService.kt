package com.reareyes.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.IOException

/**
 * 前台服务：保活 HTTP 服务 + 状态自动衰减（完成/出错 30 秒后打瞌睡）。
 */
class EyesService : Service() {

    private var remotePolling: java.util.concurrent.ScheduledExecutorService? = null
    private var server: EyesHttpServer? = null
    private var mcpServer: LanMcpServer? = null
    private val handler = Handler(Looper.getMainLooper())

    private val idleCheck = object : Runnable {
        override fun run() {
            EyesBus.sleepIfInactive(SleepSettings.load(this@EyesService) * 1000L)
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Robot Eyes", NotificationManager.IMPORTANCE_MIN)
        )
        val notif = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Robot Eyes 运行中")
            .setContentText("HTTP :$PORT · 背屏电子眼")
            .setSmallIcon(R.drawable.ic_eyes)
            .setOngoing(true)
            .build()
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notif)
        }

        remotePolling = RemoteConnection.startPolling(applicationContext)
        server = EyesHttpServer(applicationContext, PORT).also { it.start() }
        handler.postDelayed(idleCheck, 2000)
        EyesBus.log("service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (mcpServer == null) {
            try {
                mcpServer = LanMcpServer(this).also { it.start() }
                EyesBus.log("手机局域网服务已启动")
            } catch (_: IOException) {
                EyesBus.log("手机局域网服务启动失败，请检查端口 ${LanMcpSettings.PORT} 是否被占用")
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(idleCheck)
        remotePolling?.shutdownNow()
        EyesBus.Transport.entries.forEach(EyesBus::clearDesktopSnapshot)
        server?.shutdown()
        mcpServer?.shutdown()
        EyesBus.clearAgentStates()
        EyesBus.log("service stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val PORT = 8788
        private const val CHANNEL_ID = "eyes"
        private const val NOTIF_ID = 1
    }
}
