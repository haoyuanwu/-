package com.reareyes.app

internal object CyberColors {
    val background = 0xFF070C14.toInt()
    val surface = 0xFF101B29.toInt()
    val raised = 0xFF152438.toInt()
    val line = 0xFF30445C.toInt()
    val text = 0xFFE9F6FF.toInt()
    val muted = 0xFFA7BBD0.toInt()
    val cyan = 0xFF77E8F4.toInt()
    val violet = 0xFFBDABFC.toInt()

    fun forState(state: EyeState): Int = when (state) {
        EyeState.THINKING -> cyan
        EyeState.QUESTION -> 0xFFFFCC75.toInt()
        EyeState.DONE -> 0xFF88EFAD.toInt()
        EyeState.ERROR -> 0xFFFF93AA.toInt()
        EyeState.STOPPED -> muted
        EyeState.SLEEP -> violet
        EyeState.IDLE -> 0xFFC1D8FA.toInt()
    }

    fun alpha(color: Int, alpha: Int): Int = (color and 0xFFFFFF) or (alpha shl 24)
}
