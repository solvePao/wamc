package com.androidwebcam.app.camera

/** TextureView has already applied sensor orientation (and front-camera mirroring). */
data class PreviewOrientation(val transformTurns: Int = 0, val labelTurns: Int = 0)

/** One applied capture configuration; encoder callbacks must belong to this generation. */
data class StreamOrientation(
    val cameraId: String,
    val generation: Int,
    val halMode: Int?,
    val streamTurns: Int,
    val preview: PreviewOrientation,
) {
    fun belongsTo(cameraId: String, generation: Int): Boolean =
        this.cameraId == cameraId && this.generation == generation

    companion object {
        fun create(
            cameraId: String,
            generation: Int,
            sensorDegrees: Int,
            displayDegrees: Int,
            facingFront: Boolean,
            manualTurns: Int,
            halModes: Set<Int>,
        ): StreamOrientation {
            val total = CameraOrientation.totalTurns(
                sensorDegrees, displayDegrees, facingFront, manualTurns)
            val plan = RotationPlanner.plan(total, halModes)
            // HAL rotation appears reversed in the mirrored front TextureView.
            val previewHalTurns = (plan.halRotateMode ?: 0) * if (facingFront) -1 else 1
            val previewTurns = (-displayDegrees / 90 + manualTurns - previewHalTurns) and 3
            return StreamOrientation(cameraId, generation, plan.halRotateMode,
                plan.configRotation, PreviewOrientation(previewTurns, total))
        }
    }
}

/** Limits update frequency without discarding the final display event. */
class RotationUpdateSchedule(private val intervalMs: Long) {
    private var lastAppliedMs: Long? = null

    fun delayMs(nowMs: Long): Long =
        lastAppliedMs?.let { (intervalMs - (nowMs - it)).coerceAtLeast(0) } ?: 0

    fun didApply(nowMs: Long) { lastAppliedMs = nowMs }
}
