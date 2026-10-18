package com.androidwebcam.app

import com.androidwebcam.app.camera.RotationUpdateSchedule
import com.androidwebcam.app.camera.StreamOrientation
import org.junit.Assert.*
import org.junit.Test

class StreamOrientationTest {
    private fun orientation(
        front: Boolean = false, display: Int = 0, manual: Int = 0,
        modes: Set<Int> = emptySet(), generation: Int = 1,
    ) = StreamOrientation.create(if (front) "1" else "0", generation,
        if (front) 270 else 90, display, front, manual, modes)

    @Test fun textureViewDoesNotRepeatSensorCompensation() {
        for (front in listOf(false, true)) {
            val portrait = orientation(front)
            assertEquals(0, portrait.preview.transformTurns)
            assertEquals(if (front) 3 else 1, portrait.streamTurns)
            assertEquals(portrait.streamTurns, portrait.preview.labelTurns)
        }
    }

    @Test fun allDisplayOrientationsAndManualTurns() {
        val backStream = listOf(1, 0, 3, 2)
        val frontStream = listOf(3, 0, 1, 2)
        val preview = listOf(0, 3, 2, 1)
        for (front in listOf(false, true)) {
            for (display in 0..3) {
                for (manual in 0..4) {
                    val result = orientation(front, display * 90, manual)
                    val expected = (if (front) frontStream else backStream)[display]
                    assertEquals((expected + manual) and 3, result.streamTurns)
                    assertEquals((preview[display] + manual) and 3, result.preview.transformTurns)
                    assertEquals((expected + manual) and 3, result.preview.labelTurns)
                }
            }
        }
    }

    @Test fun halRotationIsRemovedFromBothConsumers() {
        val modes = setOf(0, 1, 2, 3)
        val back = orientation(modes = modes)
        assertEquals(1, back.halMode)
        assertEquals(0, back.streamTurns)
        assertEquals(3, back.preview.transformTurns)
        val front = orientation(front = true, modes = modes)
        assertEquals(3, front.halMode)
        assertEquals(0, front.streamTurns)
        assertEquals(3, front.preview.transformTurns)
        assertEquals(3, front.preview.labelTurns)
    }

    @Test fun metadataFallbackExplicitlyDisablesHalAutoRotation() {
        val fallback = orientation(modes = setOf(0))
        assertEquals(0, fallback.halMode)
        assertEquals(1, fallback.streamTurns)
        assertEquals(0, fallback.preview.transformTurns)
        val upright = orientation(display = 90, modes = setOf(0, 1, 2, 3))
        assertEquals(0, upright.halMode)
        assertEquals(0, upright.streamTurns)
    }

    @Test fun metadataChangesDuringStartupKeepCurrentGeneration() {
        val started = orientation()
        val rotatedBeforeConfig = orientation(display = 90)
        assertTrue(rotatedBeforeConfig.belongsTo(started.cameraId, started.generation))
        assertEquals(0, rotatedBeforeConfig.streamTurns)
        assertFalse(orientation(generation = 2).belongsTo(started.cameraId, started.generation))
        assertFalse(orientation(front = true).belongsTo(started.cameraId, started.generation))
    }

    @Test fun burstEventsRetainFinalUpdateWithinInterval() {
        val schedule = RotationUpdateSchedule(500)
        assertEquals(0L, schedule.delayMs(0))
        schedule.didApply(0)
        // Replacing a pending callback must retain the same deadline, not discard it.
        assertEquals(400L, schedule.delayMs(100))
        assertEquals(100L, schedule.delayMs(400))
        assertEquals(0L, schedule.delayMs(500))
        schedule.didApply(500)
        assertEquals(450L, schedule.delayMs(550))
        assertEquals(0L, schedule.delayMs(1100))
    }
}
