package com.reareyes.app

import android.content.Context

internal object SleepSettings {
    private const val PREFS = "sleep_settings"
    private const val TIMEOUT_KEY = "idle_timeout_seconds"
    private const val DEFAULT_SECONDS = 90
    val durations = listOf(30, 60, 90, 120, 300, 600)

    fun load(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(TIMEOUT_KEY, DEFAULT_SECONDS).takeIf { it in durations } ?: DEFAULT_SECONDS

    fun save(context: Context, seconds: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt(TIMEOUT_KEY, seconds).apply()
    }

    fun label(seconds: Int): String =
        if (seconds % 60 == 0) "${seconds / 60} 分钟" else "$seconds 秒"
}
