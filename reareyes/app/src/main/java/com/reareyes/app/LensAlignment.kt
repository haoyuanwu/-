package com.reareyes.app

import android.content.Context

/** Coordinates in pixels on the reference 976 × 596 rear display. */
internal data class LensRing(val x: Int, val y: Int, val radius: Int) {
    fun adjusted(dx: Int = 0, dy: Int = 0, dr: Int = 0): LensRing {
        val nextRadius = (radius + dr).coerceIn(70, 153)
        val margin = nextRadius + 12
        return LensRing(
            (x + dx).coerceIn(margin, 295),
            (y + dy).coerceIn(margin, LensAlignment.HEIGHT - margin),
            nextRadius
        )
    }
}

internal data class LensAlignment(val upper: LensRing, val lower: LensRing) {
    fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt("upper_x", upper.x).putInt("upper_y", upper.y).putInt("upper_radius", upper.radius)
            .putInt("lower_x", lower.x).putInt("lower_y", lower.y).putInt("lower_radius", lower.radius)
            .apply()
    }

    companion object {
        const val WIDTH = 976
        const val HEIGHT = 596
        private const val PREFS = "rear_lens_alignment"
        val defaults = LensAlignment(LensRing(157, 167, 124), LensRing(157, 438, 125))

        fun load(context: Context): LensAlignment {
            val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            fun read(prefix: String, fallback: LensRing) = LensRing(
                preferences.getInt("${prefix}_x", fallback.x),
                preferences.getInt("${prefix}_y", fallback.y),
                preferences.getInt("${prefix}_radius", fallback.radius)
            ).adjusted()
            return LensAlignment(read("upper", defaults.upper), read("lower", defaults.lower))
        }
    }
}
