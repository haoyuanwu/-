package com.reareyes.app

enum class EyeState(val label: String, private val legacyLabel: String) {
    THINKING("运行中", "WORKING"),
    QUESTION("等待确认", "NEEDS YOU"),
    DONE("已完成", "DONE"),
    ERROR("运行出错", "ERROR"),
    STOPPED("已停止", "STOPPED"),
    SLEEP("休眠", "Zzz"),
    IDLE("待机", "IDLE");

    companion object {
        fun of(s: String?): EyeState {
            if (s == null) return IDLE
            return entries.firstOrNull {
                it.name.equals(s, true) || it.label == s || it.legacyLabel.equals(s, true)
            } ?: IDLE
        }
    }
}
