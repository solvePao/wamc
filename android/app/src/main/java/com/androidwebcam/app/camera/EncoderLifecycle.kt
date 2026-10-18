package com.androidwebcam.app.camera

import com.androidwebcam.app.util.AppLog

/** Small codec lifecycle boundary that can be exercised without MediaCodec hardware. */
internal interface EncoderRuntime {
    fun start()
    fun requestKeyframe()
    fun stop()
    fun release()
    fun releaseInputSurface()
}

internal class EncoderLifecycle(
    private val runtime: EncoderRuntime,
    private val profile: StreamProfile,
) {
    fun start() {
        try {
            runtime.start()
            val codecName = if (profile.codec == QualitySelector.HEVC) "HEVC" else "AVC"
            AppLog.info("VideoEncoder", "started $codecName ${profile.width}x${profile.height}@${profile.fps}")
        } catch (error: Exception) {
            AppLog.error("VideoEncoder", "failed to start encoder", error)
            throw error
        }
    }

    fun requestKeyframe() {
        runCatching { runtime.requestKeyframe() }
            .onFailure { AppLog.warning("VideoEncoder", "keyframe request rejected", it) }
    }

    fun stop() {
        runCatching { runtime.stop() }
            .onFailure { AppLog.warning("VideoEncoder", "encoder stop failed", it) }
        runCatching { runtime.release() }
            .onFailure { AppLog.warning("VideoEncoder", "encoder release failed", it) }
        runCatching { runtime.releaseInputSurface() }
            .onFailure { AppLog.warning("VideoEncoder", "input surface release failed", it) }
    }
}
