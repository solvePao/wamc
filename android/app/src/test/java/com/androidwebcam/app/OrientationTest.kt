package com.androidwebcam.app

import android.hardware.camera2.CameraCharacteristics
import com.androidwebcam.app.camera.CameraInfo
import com.androidwebcam.app.camera.CameraOrientation
import com.androidwebcam.app.camera.DefaultCamera
import com.androidwebcam.app.camera.LensType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CameraOrientationTest {

    @Test fun backSensor90NeedsQuarterTurnInPortrait() {
        assertEquals(1, CameraOrientation.totalTurns(90, 0, false, 0))
    }

    @Test fun backSensor90IsUprightInLandscape() {
        assertEquals(0, CameraOrientation.totalTurns(90, 90, false, 0))
        assertEquals(3, CameraOrientation.totalTurns(90, 180, false, 0))
        assertEquals(2, CameraOrientation.totalTurns(90, 270, false, 0))
    }

    @Test fun frontSensor270FollowsFrontRule() {
        assertEquals(3, CameraOrientation.totalTurns(270, 0, true, 0))
        assertEquals(0, CameraOrientation.totalTurns(270, 90, true, 0))
    }

    @Test fun manualTapsAddOnTopOfCompensation() {
        assertEquals(2, CameraOrientation.totalTurns(90, 0, false, 1))
        assertEquals(0, CameraOrientation.totalTurns(90, 90, false, 4))
    }
}

class DefaultCameraTest {

    private fun cam(id: String, facing: Int, lens: LensType = LensType.OTHER) =
        CameraInfo(id, facing, lens, "cam $id")

    private val back = CameraCharacteristics.LENS_FACING_BACK
    private val front = CameraCharacteristics.LENS_FACING_FRONT

    @Test fun prefersFrontOverMainBack() {
        val cams = listOf(cam("0", back, LensType.MAIN), cam("1", front, LensType.FRONT))
        assertEquals("1", DefaultCamera.pickId(cams, null))
    }

    @Test fun savedChoiceAlwaysWins() {
        val cams = listOf(cam("0", back, LensType.MAIN), cam("1", front, LensType.FRONT))
        assertEquals("0", DefaultCamera.pickId(cams, "0"))
    }

    @Test fun unknownSavedIdFallsThroughToFront() {
        val cams = listOf(cam("0", back, LensType.MAIN), cam("1", front, LensType.FRONT))
        assertEquals("1", DefaultCamera.pickId(cams, "9"))
    }

    @Test fun noFrontFallsBackToMainBackThenFirst() {
        val backs = listOf(cam("0", back, LensType.ULTRA_WIDE), cam("2", back, LensType.MAIN))
        assertEquals("2", DefaultCamera.pickId(backs, null))
        assertEquals("0", DefaultCamera.pickId(listOf(backs[0]), null))
    }

    @Test fun emptyListReturnsNull() {
        assertNull(DefaultCamera.pickId(emptyList(), null))
    }
}
