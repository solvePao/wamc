package com.androidwebcam.app.camera

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.FakeCameraDevice
import android.util.Size
import android.util.SizeF
import android.view.Surface
import com.androidwebcam.app.ui.SquareTextureView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowCameraCharacteristics

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CameraHardwareRuntimeTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun addCamera() {
        val characteristics = ShadowCameraCharacteristics.newCameraCharacteristics()
        shadowOf(characteristics).apply {
            set(CameraCharacteristics.LENS_FACING, CameraCharacteristics.LENS_FACING_BACK)
            set(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS, floatArrayOf(5f))
            set(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE, SizeF(6.4f, 4.8f))
            set(CameraCharacteristics.SENSOR_ORIENTATION, 90)
            set(CameraCharacteristics.SCALER_AVAILABLE_ROTATE_AND_CROP_MODES, intArrayOf(0, 1))
            set(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES, intArrayOf(CaptureRequest.EDGE_MODE_FAST))
            set(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES,
                intArrayOf(CaptureRequest.NOISE_REDUCTION_MODE_FAST))
        }
        shadowOf(context.getSystemService(CameraManager::class.java)).addCamera("0", characteristics)
    }

    @Test fun enumeratesHardwareMetadataAndUsesSafeSizeFallback() {
        addCamera()
        val controller = CameraController(context)
        try {
            assertEquals(listOf("0"), controller.availableCameras.map { it.id })
            assertEquals(90, controller.sensorOrientation("0"))
            assertEquals(setOf(0, 1), controller.rotateAndCropModes("0"))
            assertEquals(emptySet<Int>(), controller.rotateAndCropModes("missing"))
            assertEquals(Size(1280, 720), controller.chooseSize("0", 1920, 1080))
            val texture = SurfaceTexture(0)
            try { controller.setPreviewTransformHint(texture, 320, 240) } finally { texture.release() }
        } finally { controller.close() }
    }

    @Test fun configuredCaptureRequestTargetsSurfaceAndAppliesEnhancements() {
        addCamera()
        val metadataClass = Class.forName("android.hardware.camera2.impl.CameraMetadataNative")
        val metadata = metadataClass.getConstructor().newInstance()
        val builder = CaptureRequest.Builder::class.java.getDeclaredConstructor(
            metadataClass, Boolean::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            String::class.java, Set::class.java,
        ).newInstance(metadata, false, -1, "0", null)
        val device = FakeCameraDevice(true, null).apply { setRequestBuilder(builder) }
        val controller = CameraController(context, null, CameraOpener { _, callback, _ -> callback.onOpened(device) })
        val texture = SurfaceTexture(0)
        val surface = Surface(texture)
        try {
            controller.lowLatencyEnhancement = true
            controller.open(null, surface, 640, 480, 1)
            val request = device.lastSession.request
            assertNotNull(request)
            assertTrue((CaptureRequest::class.java.getMethod("getTargets").invoke(request) as Collection<*>).contains(surface))
            assertEquals(CaptureRequest.EDGE_MODE_FAST, builder.get(CaptureRequest.EDGE_MODE))
            assertEquals(1, builder.get(CaptureRequest.SCALER_ROTATE_AND_CROP))
            var rejected: String? = null
            // Listener is captured when open begins, so reopen to attach it.
            controller.rotationRejectedListener = { rejected = it }
            controller.open(null, surface, 640, 480, 1)
            val session = device.lastSession
            val result = org.robolectric.shadows.ShadowTotalCaptureResult.newTotalCaptureResult().also {
                org.robolectric.shadow.api.Shadow.extract<org.robolectric.shadows.ShadowTotalCaptureResult>(it)
                    .set(android.hardware.camera2.CaptureResult.SCALER_ROTATE_AND_CROP, 0)
            }
            session.callback.onCaptureCompleted(session, session.request, result)
            assertEquals("0", rejected)
            assertTrue(session.isRepeatingStopped)
            session.callback.onCaptureCompleted(session, session.request, result)
        } finally { controller.close(); surface.release(); texture.release() }
        assertTrue(device.lastSession.isClosed)
    }

    @Test fun frameworkOpenerAndStaleCallbacksReleaseDevices() {
        addCamera()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(android.Manifest.permission.CAMERA)
        val controller = CameraController(context)
        val texture = SurfaceTexture(0)
        val surface = Surface(texture)
        try {
            controller.open(null, surface, 640, 480, null)
            val cameraThread = CameraController::class.java.getDeclaredField("thread").apply { isAccessible = true }
                .get(controller) as android.os.HandlerThread
            shadowOf(cameraThread.looper).idle()
        } finally { controller.close(); surface.release(); texture.release() }
    }

    @Test fun sessionConfiguredAfterCloseIsReleasedWithoutRepeating() {
        val device = FakeCameraDevice(true, null).apply { setDeferConfiguration(true) }
        val controller = CameraController(context, emptyList(), CameraOpener { _, value, _ -> value.onOpened(device) })
        val texture = SurfaceTexture(0)
        val surface = Surface(texture)
        try {
            controller.open(null, surface, 640, 480, null)
            controller.closeCapture()
            device.sessionCallback.onConfigured(device.lastSession)
            assertTrue(device.lastSession.isClosed)
            assertNull(device.lastSession.request)
        } finally { controller.close(); surface.release(); texture.release() }
    }

    @Test fun staleSessionGenerationRejectsDeviceBeforeConfiguration() {
        val controller = CameraController(context, emptyList())
        val texture = SurfaceTexture(0)
        val surface = Surface(texture)
        val device = FakeCameraDevice()
        try {
            CameraController::class.java.declaredMethods.single { it.name == "configureSession" }
                .apply { isAccessible = true }
                .invoke(controller, device, null, surface, "0", null, -1, null, null)
            assertTrue(device.isClosed)
        } finally { controller.close(); surface.release(); texture.release() }
    }

    @Test fun callbackDisconnectAndLateOpenHaveSeparateLifetimes() {
        var callback: android.hardware.camera2.CameraDevice.StateCallback? = null
        val controller = CameraController(context, emptyList(), CameraOpener { _, value, _ -> callback = value })
        val texture = SurfaceTexture(0)
        val surface = Surface(texture)
        var error: String? = null
        controller.openErrorListener = { error = it }
        try {
            controller.open(null, surface, 640, 480, null)
            callback!!.onDisconnected(FakeCameraDevice())
            assertEquals("camera disconnected", error)
            controller.closeCapture()
            val late = FakeCameraDevice()
            callback!!.onOpened(late)
            assertTrue(late.isClosed)
        } finally { controller.close(); surface.release(); texture.release() }
    }

    @Test fun backCameraFallbackDoesNotRequireMainLens() {
        val cameras = listOf(CameraInfo("wide", 1, LensType.ULTRA_WIDE, "Wide"),
            CameraInfo("front", 0, LensType.FRONT, "Front"))
        val controller = CameraController(context, cameras)
        try { assertEquals("wide" to "front", controller.cameraIds()) } finally { controller.close() }
        assertEquals(listOf(EnhancementLevel.OFF, EnhancementLevel.SLIGHT), EnhancementLevel.entries)
        assertTrue(LensType.entries.contains(LensType.OTHER))
        assertEquals(android.hardware.camera2.CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG,
            EnhancementModes.pickEdgeMode(intArrayOf(android.hardware.camera2.CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG), true))
        assertEquals(android.hardware.camera2.CaptureRequest.NOISE_REDUCTION_MODE_ZERO_SHUTTER_LAG,
            EnhancementModes.pickNoiseReductionMode(intArrayOf(android.hardware.camera2.CaptureRequest.NOISE_REDUCTION_MODE_ZERO_SHUTTER_LAG), true))
    }

    @Test fun squarePreviewHandlesUnconstrainedMeasurements() {
        val dashboard = com.androidwebcam.app.ui.DashboardLayout(context)
        dashboard.addView(android.view.View(context))
        assertEquals(android.view.ViewGroup.LayoutParams.MATCH_PARENT, dashboard.getChildAt(0).layoutParams.width)
        val preview = SquareTextureView(context)
        val unspecified = android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED)
        val exact = android.view.View.MeasureSpec.makeMeasureSpec(120, android.view.View.MeasureSpec.EXACTLY)
        for ((width, height, expected) in listOf(Triple(unspecified, unspecified, 0),
            Triple(unspecified, exact, 120), Triple(exact, unspecified, 120))) {
            preview.measure(width, height)
            assertEquals(expected, preview.measuredWidth)
            assertEquals(expected, preview.measuredHeight)
        }
    }
}
