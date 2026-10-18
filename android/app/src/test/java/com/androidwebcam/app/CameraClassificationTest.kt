package com.androidwebcam.app

import android.hardware.camera2.CameraCharacteristics
import com.androidwebcam.app.camera.CameraClassifier
import com.androidwebcam.app.camera.CameraClassifier.RawCameraProps
import com.androidwebcam.app.camera.LensType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class CameraClassificationTest {

    @Test
    fun testSingleBackAndFrontCameras() {
        val cameras = listOf(
            RawCameraProps(
                id = "0",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 5.0f,
                sensorWidth = 6.4f,
                sensorHeight = 4.8f,
                eq35mm = CameraClassifier.calculateEquivalent35mm(5.0f, 6.4f, 4.8f)
            ),
            RawCameraProps(
                id = "1",
                facing = CameraCharacteristics.LENS_FACING_FRONT,
                focalLength = 3.0f,
                sensorWidth = 4.0f,
                sensorHeight = 3.0f,
                eq35mm = CameraClassifier.calculateEquivalent35mm(3.0f, 4.0f, 3.0f)
            )
        )

        val result = CameraClassifier.classifyRawCameras(cameras)
        assertEquals(2, result.size)

        val back = result.first { it.facing == CameraCharacteristics.LENS_FACING_BACK }
        assertEquals("0", back.id)
        assertEquals(LensType.MAIN, back.lensType)
        assertEquals("Back Camera", back.displayName)

        val front = result.first { it.facing == CameraCharacteristics.LENS_FACING_FRONT }
        assertEquals("1", front.id)
        assertEquals(LensType.FRONT, front.lensType)
        assertEquals("Front Camera", front.displayName)
    }

    @Test
    fun testMultiBackCameraDetectionWithUltraWideAndTelephoto() {
        // Typical modern multi-camera Android device:
        // ID 0: Main (Wide ~26mm eq)
        // ID 1: Front
        // ID 2: Ultra-Wide (~13mm eq)
        // ID 3: Telephoto (~70mm eq)
        val mainW = 7.0f; val mainH = 5.25f
        val auxW = 5.6f; val auxH = 4.2f

        val cameras = listOf(
            RawCameraProps(
                id = "0",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 5.4f,
                sensorWidth = mainW,
                sensorHeight = mainH,
                eq35mm = CameraClassifier.calculateEquivalent35mm(5.4f, mainW, mainH)
            ),
            RawCameraProps(
                id = "1",
                facing = CameraCharacteristics.LENS_FACING_FRONT,
                focalLength = 3.2f,
                sensorWidth = auxW,
                sensorHeight = auxH,
                eq35mm = CameraClassifier.calculateEquivalent35mm(3.2f, auxW, auxH)
            ),
            RawCameraProps(
                id = "2",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 1.8f,
                sensorWidth = auxW,
                sensorHeight = auxH,
                eq35mm = CameraClassifier.calculateEquivalent35mm(1.8f, auxW, auxH)
            ),
            RawCameraProps(
                id = "3",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 11.0f,
                sensorWidth = auxW,
                sensorHeight = auxH,
                eq35mm = CameraClassifier.calculateEquivalent35mm(11.0f, auxW, auxH)
            )
        )

        val result = CameraClassifier.classifyRawCameras(cameras)
        assertEquals(4, result.size)

        val main = result.firstOrNull { it.id == "0" }
        assertNotNull(main)
        assertEquals(LensType.MAIN, main!!.lensType)
        assertEquals("Back Camera (Main)", main.displayName)

        val ultraWide = result.firstOrNull { it.id == "2" }
        assertNotNull(ultraWide)
        assertEquals(LensType.ULTRA_WIDE, ultraWide!!.lensType)
        assertEquals("Back Camera (Ultra Wide)", ultraWide.displayName)

        val telephoto = result.firstOrNull { it.id == "3" }
        assertNotNull(telephoto)
        assertEquals(LensType.TELEPHOTO, telephoto!!.lensType)
        assertEquals("Back Camera (Telephoto)", telephoto.displayName)

        val front = result.firstOrNull { it.id == "1" }
        assertNotNull(front)
        assertEquals(LensType.FRONT, front!!.lensType)
        assertEquals("Front Camera", front.displayName)

        // Ensure default camera is Main (ID 0) and NOT Ultra-Wide (ID 2)
        val defaultBack = result.firstOrNull {
            it.facing == CameraCharacteristics.LENS_FACING_BACK && it.lensType == LensType.MAIN
        }
        assertEquals("0", defaultBack?.id)
    }

    @Test
    fun testFallbackWithoutSensorPhysicalSize() {
        // Sensor size unavailable, rely on relative focal lengths
        val cameras = listOf(
            RawCameraProps(
                id = "0",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 5.0f,
                sensorWidth = null,
                sensorHeight = null,
                eq35mm = null
            ),
            RawCameraProps(
                id = "2",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = 2.0f,
                sensorWidth = null,
                sensorHeight = null,
                eq35mm = null
            )
        )

        val result = CameraClassifier.classifyRawCameras(cameras)
        assertEquals(2, result.size)

        val main = result.first { it.id == "0" }
        assertEquals(LensType.MAIN, main.lensType)

        val ultraWide = result.first { it.id == "2" }
        assertEquals(LensType.ULTRA_WIDE, ultraWide.lensType)
    }

    @Test
    fun testFallbackWithoutFocalLengths() {
        // No focal length info at all
        val cameras = listOf(
            RawCameraProps(
                id = "0",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = null,
                sensorWidth = null,
                sensorHeight = null,
                eq35mm = null
            ),
            RawCameraProps(
                id = "2",
                facing = CameraCharacteristics.LENS_FACING_BACK,
                focalLength = null,
                sensorWidth = null,
                sensorHeight = null,
                eq35mm = null
            )
        )

        val result = CameraClassifier.classifyRawCameras(cameras)
        assertEquals(2, result.size)

        val main = result.first { it.id == "0" }
        assertEquals(LensType.MAIN, main.lensType)
        assertEquals("Back Camera (Main)", main.displayName)
    }
}
