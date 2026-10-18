package com.androidwebcam.app.camera

/**
 * Restart epoch and rejoin guards.
 *
 * Every pipeline rebuild (setting change, camera switch, rotation with a HAL
 * mode change, transport-triggered restart) bumps the generation, flushes
 * stale VIDEO from [com.androidwebcam.app.transport.TransportHub], resends
 * CONFIG, and forces an IDR — so the Mac never decodes pre-restart P-frames
 * against a fresh decoder session (the WAMC/FaceTime freeze).
 */
object StreamGeneration {
    fun next(current: Int): Int = if (current >= Int.MAX_VALUE) 1 else current + 1
}

/** Forwards only the first keyframe and everything after it. */
class RestartGate {
    var awaitingKeyframe: Boolean = false
        private set

    fun reset() {
        awaitingKeyframe = true
    }

    fun shouldForward(isKeyframe: Boolean): Boolean {
        if (!awaitingKeyframe) return true
        if (!isKeyframe) return false
        awaitingKeyframe = false
        return true
    }
}

/** Pure rotation-change decision: metadata resend vs full pipeline restart. */
object RotationResendPolicy {
    enum class Action { NONE, RESEND_CONFIG, RESTART }

    /**
     * [hasConfig] is false before the first CONFIG was sent. A HAL rotate
     * mode change needs a restart (the mode is fixed at session configure
     * time); a metadata-only change just resends CONFIG plus a keyframe.
     */
    fun decide(
        lastHalMode: Int?,
        lastMacRotation: Int,
        newHalMode: Int?,
        newMacRotation: Int,
        hasConfig: Boolean,
    ): Action {
        if (!hasConfig) return Action.NONE
        if (lastHalMode == newHalMode && lastMacRotation == newMacRotation) return Action.NONE
        return if (lastHalMode != newHalMode) Action.RESTART else Action.RESEND_CONFIG
    }
}
