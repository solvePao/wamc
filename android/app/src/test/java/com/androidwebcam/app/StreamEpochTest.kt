package com.androidwebcam.app

import com.androidwebcam.app.camera.RestartGate
import com.androidwebcam.app.camera.RotationResendPolicy
import com.androidwebcam.app.camera.StreamGeneration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamEpochTest {

    @Test fun generationIncrementsMonotonically() {
        assertEquals(1, StreamGeneration.next(0))
        assertEquals(42, StreamGeneration.next(41))
    }

    @Test fun generationWrapsWithoutStickingAtMax() {
        assertEquals(1, StreamGeneration.next(Int.MAX_VALUE))
    }

    @Test fun gateForwardsEverythingBeforeReset() {
        val gate = RestartGate()
        assertTrue(gate.shouldForward(false))
        assertTrue(gate.shouldForward(true))
    }

    @Test fun gateDropsPreIdrFramesAfterRestart() {
        val gate = RestartGate()
        gate.reset()
        assertTrue(gate.awaitingKeyframe)
        assertFalse(gate.shouldForward(false))
        assertFalse(gate.shouldForward(false))
        assertTrue(gate.shouldForward(true))
        assertTrue(gate.shouldForward(false))
    }

    @Test fun rotationNoChangeNeedsNothing() {
        assertEquals(RotationResendPolicy.Action.NONE,
            RotationResendPolicy.decide(null, 0, null, 0, hasConfig = true))
        assertEquals(RotationResendPolicy.Action.NONE,
            RotationResendPolicy.decide(1, 0, 1, 0, hasConfig = true))
    }

    @Test fun rotationWithoutConfigNeedsNothing() {
        assertEquals(RotationResendPolicy.Action.NONE,
            RotationResendPolicy.decide(null, -1, null, 1, hasConfig = false))
    }

    @Test fun metadataRotationOnlyResendsConfig() {
        assertEquals(RotationResendPolicy.Action.RESEND_CONFIG,
            RotationResendPolicy.decide(null, 0, null, 1, hasConfig = true))
    }

    @Test fun halModeChangeNeedsRestart() {
        assertEquals(RotationResendPolicy.Action.RESTART,
            RotationResendPolicy.decide(null, 1, 1, 0, hasConfig = true))
        assertEquals(RotationResendPolicy.Action.RESTART,
            RotationResendPolicy.decide(1, 0, 2, 0, hasConfig = true))
    }
}
