package com.reareyes.app

import android.content.Context

internal data class RearDisplaySettings(val keepOn: Boolean, val brightness: Int) {
    fun save(context: Context) {
        preferences(context).edit()
            .putBoolean(KEEP_ON, keepOn)
            .putInt(BRIGHTNESS, brightness.coerceIn(MIN_BRIGHTNESS, 100))
            .apply()
    }

    companion object {
        const val MIN_BRIGHTNESS = 10
        private const val KEEP_ON = "keep_on"
        private const val BRIGHTNESS = "brightness_percent"

        fun preferences(context: Context) =
            context.getSharedPreferences("rear_display", Context.MODE_PRIVATE)

        fun load(context: Context): RearDisplaySettings = preferences(context).let {
            RearDisplaySettings(
                it.getBoolean(KEEP_ON, true),
                it.getInt(BRIGHTNESS, 60).coerceIn(MIN_BRIGHTNESS, 100),
            )
        }
    }
}
