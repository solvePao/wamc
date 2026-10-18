package com.androidwebcam.app

import android.hardware.camera2.CaptureRequest
import com.androidwebcam.app.camera.EnhancementModes
import org.junit.Assert.assertEquals
import org.junit.Test

class EnhancementModeTest {

    @Test
    fun disabledAlwaysMapsToOff() {
        val modes = intArrayOf(
            CaptureRequest.EDGE_MODE_HIGH_QUALITY,
            CaptureRequest.EDGE_MODE_FAST,
        )
        assertEquals(
            CaptureRequest.EDGE_MODE_OFF,
            EnhancementModes.pickEdgeMode(modes, false),
        )
        assertEquals(
            CaptureRequest.NOISE_REDUCTION_MODE_OFF,
            EnhancementModes.pickNoiseReductionMode(modes, false),
        )
    }

    @Test
    fun missingModesMapToOff() {
        assertEquals(
            CaptureRequest.EDGE_MODE_OFF,
            EnhancementModes.pickEdgeMode(null, true),
        )
        assertEquals(
            CaptureRequest.EDGE_MODE_OFF,
            EnhancementModes.pickEdgeMode(intArrayOf(), true),
        )
        assertEquals(
            CaptureRequest.NOISE_REDUCTION_MODE_OFF,
            EnhancementModes.pickNoiseReductionMode(null, true),
        )
    }

    @Test
    fun prefersHighQualityWhenAvailable() {
        assertEquals(
            CaptureRequest.EDGE_MODE_HIGH_QUALITY,
            EnhancementModes.pickEdgeMode(
                intArrayOf(
                    CaptureRequest.EDGE_MODE_OFF,
                    CaptureRequest.EDGE_MODE_FAST,
                    CaptureRequest.EDGE_MODE_HIGH_QUALITY,
                ),
                true,
            ),
        )
        assertEquals(
            CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY,
            EnhancementModes.pickNoiseReductionMode(
                intArrayOf(
                    CaptureRequest.NOISE_REDUCTION_MODE_OFF,
                    CaptureRequest.NOISE_REDUCTION_MODE_FAST,
                    CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY,
                ),
                true,
            ),
        )
    }

    @Test
    fun fallsBackToFastWithoutHighQuality() {
        assertEquals(
            CaptureRequest.EDGE_MODE_FAST,
            EnhancementModes.pickEdgeMode(
                intArrayOf(CaptureRequest.EDGE_MODE_OFF, CaptureRequest.EDGE_MODE_FAST),
                true,
            ),
        )
        assertEquals(
            CaptureRequest.NOISE_REDUCTION_MODE_FAST,
            EnhancementModes.pickNoiseReductionMode(
                intArrayOf(
                    CaptureRequest.NOISE_REDUCTION_MODE_OFF,
                    CaptureRequest.NOISE_REDUCTION_MODE_FAST,
                ),
                true,
            ),
        )
    }

    @Test
    fun unknownModesMapToOff() {
        assertEquals(
            CaptureRequest.EDGE_MODE_OFF,
            EnhancementModes.pickEdgeMode(intArrayOf(CaptureRequest.EDGE_MODE_OFF), true),
        )
        assertEquals(
            CaptureRequest.NOISE_REDUCTION_MODE_OFF,
            EnhancementModes.pickNoiseReductionMode(
                intArrayOf(CaptureRequest.NOISE_REDUCTION_MODE_OFF),
                true,
            ),
        )
    }
}
