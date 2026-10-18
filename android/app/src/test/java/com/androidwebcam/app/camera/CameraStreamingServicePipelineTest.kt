package com.androidwebcam.app.camera

import android.Manifest
import android.graphics.SurfaceTexture
import android.os.Looper
import android.view.Surface
import android.hardware.camera2.CameraCharacteristics
import android.util.Size
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CameraStreamingServicePipelineTest {
    @Test fun startupCallbacksAndLiveRestartsUseInjectedPipeline() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java).create()
        val service = serviceController.get()
        val camera = FakeStreamingCamera()
        val encoder = FakeStreamingEncoder()
        service.cameraFactory = StreamingCameraFactory { camera }
        service.encoderFactory = StreamingEncoderFactory { _, _, config, sets, frame ->
            encoder.onStarted = {
                config(byteArrayOf(0x67), byteArrayOf(0x68))
                sets(listOf(byteArrayOf(0x67, 0x64), byteArrayOf(0x68, 0x01)))
                sets(listOf(byteArrayOf(0x67, 0x64), byteArrayOf(0x68, 0x01)))
                frame(byteArrayOf(0x65, 0x01), true, 100L)
            }
            encoder
        }
        service.setActivityVisible(true)

        assertTrue(service.startStreaming(640, 480))
        assertTrue(service.streaming)
        assertEquals(1, service.streamGeneration)
        assertTrue(encoder.started)
        assertEquals(1, camera.openCount)
        assertEquals("Streaming — waiting for Mac on USB", service.currentStatus())
        val generation = service.streamGeneration
        val displayEvents = CameraStreamingService::class.java.getDeclaredField("displayListener")
            .apply { isAccessible = true }.get(service) as android.hardware.display.DisplayManager.DisplayListener
        displayEvents.onDisplayAdded(1)
        displayEvents.onDisplayRemoved(1)
        service.notifyConfigurationChanged()
        shadowOf(Looper.getMainLooper()).idleFor(500, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(generation, service.streamGeneration)
        val hubField = CameraStreamingService::class.java.getDeclaredField("hub").apply {
            isAccessible = true
        }
        (hubField.get(service) as com.androidwebcam.app.transport.TransportHub).onPeerAttached?.invoke()
        service.setPreviewSurface(null)
        assertEquals(1, camera.captureCloseCount)
        assertEquals(1, service.streamGeneration)
        camera.openErrorListener?.invoke("simulated async open error")
        assertTrue(service.hasCameraError) // fake camera reports the asynchronous open failure
        assertTrue(service.currentStatus().startsWith("Camera open failed:"))

        service.handleControl(mapOf("cmd" to "hello", "codecs" to "avc"))
        for (rotation in listOf(Surface.ROTATION_90, Surface.ROTATION_180, Surface.ROTATION_270)) {
            val display = service.getSystemService(android.view.WindowManager::class.java).defaultDisplay
            shadowOf(display).setRotation(rotation)
            service.notifyConfigurationChanged()
            shadowOf(Looper.getMainLooper()).idleFor(500, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
        service.rotate()
        shadowOf(Looper.getMainLooper()).idleFor(500, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(generation, service.streamGeneration)
        service.setEnhancementEnabled(false)
        assertEquals(2, service.streamGeneration)
        service.setQuality(StreamQuality.BALANCED)
        assertEquals(3, service.streamGeneration)
        val preview = Surface(SurfaceTexture(1))
        service.setPreviewSurface(preview)
        assertEquals(4, service.streamGeneration)
        service.stopStreaming()
        assertFalse(service.streaming)
        assertTrue(camera.captureCloseCount > 0)
        assertTrue(camera.closeCount > 0)
        assertTrue(encoder.stopped)
        preview.release()

        serviceController.destroy()
    }

    @Test fun encoderConstructionFailureStopsPipelineAndRetainsErrorStatus() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java).create()
        val service = serviceController.get()
        service.cameraFactory = StreamingCameraFactory { FakeStreamingCamera() }
        service.encoderFactory = StreamingEncoderFactory { _, _, _, _, _ ->
            throw IllegalStateException("test codec unavailable")
        }
        service.setActivityVisible(true)

        assertFalse(service.startStreaming(640, 480))
        assertFalse(service.streaming)
        assertTrue(service.hasCameraError)
        assertEquals("Encoder failed: test codec unavailable", service.currentStatus())
        serviceController.destroy()
    }

    @Test fun rotationRejectionFallsBackToMetadataThenStopsIfRejectedAgain() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java).create()
        val service = serviceController.get()
        val camera = FakeStreamingCamera(rotateModes = setOf(1))
        service.cameraFactory = StreamingCameraFactory { camera }
        service.encoderFactory = StreamingEncoderFactory { _, _, _, _, _ -> FakeStreamingEncoder() }
        service.setActivityVisible(true)
        assertTrue(service.startStreaming(640, 480))

        camera.rotationRejectedListener?.invoke("fake")
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(service.streaming)
        assertEquals(2, service.streamGeneration)
        camera.rotationRejectedListener?.invoke("fake")
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(service.streaming)
        assertEquals("Camera cannot disable automatic rotation", service.currentStatus())

        serviceController.destroy()
    }

    @Test
    @Config(sdk = [28], shadows = [VideoEncoderRobolectricTest.SurfaceCodecShadow::class,
        com.androidwebcam.app.WifiDiscoveryAdvertiserTest.RecordingNsdManager::class])
    fun defaultEncoderAndLegacyForegroundSupportWifiDiscovery() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val connectivity = app.getSystemService(android.net.ConnectivityManager::class.java)
        shadowOf(connectivity).setActiveNetworkInfo(org.robolectric.shadows.ShadowNetworkInfo.newInstance(
            android.net.NetworkInfo.DetailedState.CONNECTED, android.net.ConnectivityManager.TYPE_WIFI, 0, true, true))
        org.robolectric.shadows.ShadowMediaCodec.addEncoder("video/avc",
            org.robolectric.shadows.ShadowMediaCodec.CodecConfig(4, 4,
                object : org.robolectric.shadows.ShadowMediaCodec.CodecConfig.Codec {
                    override fun process(input: java.nio.ByteBuffer, output: java.nio.ByteBuffer) = Unit
                    override fun onConfigured(format: android.media.MediaFormat, surface: Surface?,
                        crypto: android.media.MediaCrypto?, flags: Int) = Unit
                }))
        val controller = Robolectric.buildService(CameraStreamingService::class.java).create()
        val service = controller.get()
        try {
            assertEquals(emptyList<CameraInfo>(), service.getAvailableCameras())
            service.cameraFactory = StreamingCameraFactory { FakeStreamingCamera() }
            service.setActivityVisible(true)
            assertTrue(service.startStreaming(640, 480))
            assertTrue(service.streaming)
            val nsd = org.robolectric.shadow.api.Shadow.extract<com.androidwebcam.app.WifiDiscoveryAdvertiserTest.RecordingNsdManager>(
                app.getSystemService(android.net.nsd.NsdManager::class.java))
            assertEquals(1, nsd.registered)
            service.stopStreaming()
        } finally {
            controller.destroy()
            org.robolectric.shadows.ShadowMediaCodec.clearCodecs()
        }
    }

    @Test fun unavailableCameraManagerReturnsEmptyInventory() {
        val controller = Robolectric.buildService(CameraStreamingService::class.java).create()
        try {
            val service = controller.get()
            org.robolectric.shadow.api.Shadow.extract<org.robolectric.shadows.ShadowContextImpl>(service.baseContext)
                .setSystemService(android.content.Context.CAMERA_SERVICE, null)
            assertEquals(emptyList<CameraInfo>(), service.getAvailableCameras())
        } finally { controller.destroy() }
    }

    @Test
    @Config(shadows = [DeniedForegroundShadow::class])
    fun foregroundDenialKeepsIdleListenerAndRejectsStreaming() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val controller = Robolectric.buildService(CameraStreamingService::class.java).create()
        val service = controller.get()
        try {
            assertEquals(android.app.Service.START_STICKY, service.onStartCommand(null, 0, 1))
            service.setActivityVisible(true)
            assertFalse(service.startStreaming(640, 480))
            assertEquals("Camera service start denied: simulated foreground denial", service.currentStatus())
            assertFalse(service.streaming)
        } finally { controller.destroy() }
    }

    @org.robolectric.annotation.Implements(android.app.Service::class)
    class DeniedForegroundShadow : org.robolectric.shadows.ShadowService() {
        @org.robolectric.annotation.Implementation
        override fun startForeground(id: Int, notification: android.app.Notification) {
            throw SecurityException("simulated foreground denial")
        }
        @org.robolectric.annotation.Implementation
        override fun startForeground(id: Int, notification: android.app.Notification, type: Int) {
            throw SecurityException("simulated foreground denial")
        }
    }

    private class FakeStreamingCamera(
        private val rotateModes: Set<Int> = emptySet(),
    ) : StreamingCamera {
        override val availableCameras = listOf(CameraInfo(
            "fake", CameraCharacteristics.LENS_FACING_BACK, LensType.MAIN, "Fake",
        ))
        override val activeCameraId = "fake"
        override val facingBack = true
        override var enhancementEnabled = true
        override var lowLatencyEnhancement = false
        override var openErrorListener: ((String) -> Unit)? = null
        override var rotationRejectedListener: ((String) -> Unit)? = null
        var openCount = 0
        var captureCloseCount = 0
        var closeCount = 0

        override fun selectCamera(id: String) = Unit
        override fun switchCamera() = Unit
        override fun sensorOrientation(cameraId: String) = 90
        override fun rotateAndCropModes(cameraId: String) = rotateModes
        override fun chooseSize(cameraId: String, wantW: Int, wantH: Int) = Size(640, 480)
        override fun open(preview: Surface?, encoderSurface: Surface, wantW: Int, wantH: Int,
            halRotateMode: Int?) {
            openCount++
        }
        override fun closeCapture() { captureCloseCount++ }
        override fun close() { closeCount++ }
    }

    private class FakeStreamingEncoder : StreamingEncoder {
        override val inputSurface = Surface(SurfaceTexture(2))
        var started = false
        var stopped = false
        var onStarted: (() -> Unit)? = null
        override fun start() { started = true; onStarted?.invoke() }
        override fun requestKeyframe() = Unit
        override fun stop() { stopped = true; inputSurface.release() }
    }
}
