package com.androidwebcam.app

import android.Manifest
import android.hardware.usb.UsbManager
import android.content.Intent
import android.content.ComponentName
import android.content.res.Configuration
import android.provider.Settings
import android.graphics.SurfaceTexture
import android.graphics.Insets
import android.widget.Button
import android.widget.Switch
import android.widget.TextView
import android.view.TextureView
import android.view.View
import android.view.Surface
import android.view.WindowInsets
import android.hardware.camera2.FakeCameraDevice
import com.androidwebcam.app.camera.CameraController
import com.androidwebcam.app.camera.CameraInfo
import com.androidwebcam.app.camera.CameraOpener
import com.androidwebcam.app.camera.CameraStreamingService
import com.androidwebcam.app.camera.LensType
import com.androidwebcam.app.camera.StreamQuality
import com.androidwebcam.app.transport.WamcDiscovery
import com.androidwebcam.app.ui.DashboardLayout
import com.androidwebcam.app.ui.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.android.controller.ServiceController
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MainActivityLifecycleTest {

    @Test fun activityRendersAndControlsAnAttachedService() {
        val application = RuntimeEnvironment.getApplication()
        val manager = application.getSystemService(android.hardware.camera2.CameraManager::class.java)
        for ((id, facing) in listOf("back" to 1, "front" to 0)) {
            val characteristics = org.robolectric.shadows.ShadowCameraCharacteristics.newCameraCharacteristics()
            shadowOf(characteristics).set(android.hardware.camera2.CameraCharacteristics.LENS_FACING, facing)
            shadowOf(manager).addCamera(id, characteristics)
        }
        application.getSharedPreferences("wamc_prefs", 0)
            .edit().putBoolean("auto_start", false).apply()
        shadowOf(application).grantPermissions(
            Manifest.permission.CAMERA,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        val activityController = ActivityTestHarness.build(
            Intent(application, MainActivity::class.java).setAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED))
            .create().start().resume()
        val activity = activityController.get()
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java)
        val service = serviceController.create().get()
        val binder = service.onBind(Intent(application, CameraStreamingService::class.java))
        val connectionField = MainActivity::class.java.getDeclaredField("connection").apply {
            isAccessible = true
        }
        val connection = connectionField.get(activity) as android.content.ServiceConnection
        connection.onServiceConnected(
            ComponentName(application, CameraStreamingService::class.java), binder)

        val preview = activity.findViewById<TextureView>(R.id.preview)
        preview.measure(
            View.MeasureSpec.makeMeasureSpec(640, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
        )
        preview.layout(0, 0, 640, 480)
        val texture = SurfaceTexture(7)
        val surfaceListener = preview.surfaceTextureListener!!
        surfaceListener.onSurfaceTextureAvailable(texture, 640, 480)
        surfaceListener.onSurfaceTextureSizeChanged(texture, 800, 600)
        surfaceListener.onSurfaceTextureUpdated(texture)
        assertTrue(surfaceListener.onSurfaceTextureDestroyed(texture))
        texture.release()

        val selector = activity.findViewById<android.widget.Spinner>(R.id.cameraSelector)
        selector.onItemSelectedListener!!.onItemSelected(selector, null, 0, 0)
        assertEquals("back", service.currentCameraId)
        selector.onItemSelectedListener!!.onNothingSelected(selector)
        service.selectCamera("front")
        assertEquals(1, selector.selectedItemPosition)
        activity.findViewById<Switch>(R.id.autoStartToggle).isChecked = true
        assertTrue(application.getSharedPreferences("wamc_prefs", 0).getBoolean("auto_start", false))
        activity.findViewById<Switch>(R.id.autoStartToggle).isChecked = false
        activity.findViewById<View>(R.id.updateMenu).performClick()
        val menu = org.robolectric.shadows.ShadowPopupMenu.getLatestPopupMenu()
        assertNotNull(menu)
        menu.dismiss()
        val toggle = activity.findViewById<Button>(R.id.toggle)
        assertTrue(toggle.isEnabled)
        toggle.performClick()
        assertTrue(activity.findViewById<TextView>(R.id.status).text.isNotEmpty())
        activity.findViewById<Button>(R.id.rotate).performClick()
        activity.findViewById<Button>(R.id.switchCamera).performClick()
        if (service.streaming) {
            toggle.performClick()
            assertFalse(service.streaming)
        }
        activity.findViewById<Switch>(R.id.wifiDiscoveryToggle).isChecked = false
        assertEquals(false, service.wifiDiscoveryEnabled)
        assertEquals(activity.getString(R.string.dashboard_ready),
            activity.findViewById<TextView>(R.id.stateBadge).text.toString())

        activityController.pause().stop().destroy()
        serviceController.destroy()
    }

    @Test fun activityKeepsCameraActionsDisabledWhenPermissionIsDenied() {
        val application = RuntimeEnvironment.getApplication()
        application.getSharedPreferences("wamc_prefs", 0)
            .edit().putBoolean("auto_start", false).apply()
        shadowOf(application).denyPermissions(Manifest.permission.CAMERA)
        val activityController = ActivityTestHarness.build()
            .create().start().resume()
        val activity = activityController.get()
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java)
        val service = serviceController.create().get()
        val binder = service.onBind(Intent(application, CameraStreamingService::class.java))
        val connection = MainActivity::class.java.getDeclaredField("connection").apply {
            isAccessible = true
        }.get(activity) as android.content.ServiceConnection
        connection.onServiceConnected(ComponentName(application, CameraStreamingService::class.java), binder)

        assertFalse(activity.findViewById<Button>(R.id.rotate).isEnabled)
        assertFalse(activity.findViewById<Button>(R.id.switchCamera).isEnabled)
        assertEquals(activity.getString(R.string.dashboard_permission_status),
            activity.findViewById<TextView>(R.id.status).text.toString())
        activity.findViewById<Button>(R.id.toggle).performClick()
        activity.onRequestPermissionsResult(1, arrayOf(Manifest.permission.CAMERA), intArrayOf(0))
        assertFalse(activity.findViewById<Button>(R.id.rotate).isEnabled)
        activity.onWindowFocusChanged(false)
        activity.onWindowFocusChanged(true)
        activityController.saveInstanceState(android.os.Bundle())

        activityController.pause().stop().destroy()
        serviceController.destroy()
    }

    @Test fun usbSetupCardOpensTheMatchingSettingsAndCanBeDismissed() {
        val application = RuntimeEnvironment.getApplication()
        application.getSharedPreferences("wamc_prefs", 0)
            .edit().putBoolean("auto_start", false).apply()
        application.getSharedPreferences("wamc_usb_prefs", 0)
            .edit().putBoolean("usb_setup_dismissed", false).apply()
        Settings.Global.putInt(application.contentResolver,
            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 1)
        val controller = ActivityTestHarness.build().create().start().resume()
        val activity = controller.get()
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.usbSetupCard).visibility)
        activity.findViewById<Button>(R.id.btnConfigureUsb).performClick()
        val opened = shadowOf(activity).nextStartedActivity
        assertEquals(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS, opened.action)
        activity.findViewById<Button>(R.id.btnDismissUsbSetup).performClick()
        assertEquals(View.GONE, activity.findViewById<View>(R.id.usbSetupCard).visibility)
        controller.pause().stop().destroy()

        Settings.Global.putInt(application.contentResolver,
            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0)
        application.getSharedPreferences("wamc_usb_prefs", 0)
            .edit().putBoolean("usb_setup_dismissed", false).apply()
        val nonDeveloperController = ActivityTestHarness.build().create().start().resume()
        val nonDeveloperActivity = nonDeveloperController.get()
        nonDeveloperActivity.findViewById<Button>(R.id.btnConfigureUsb).performClick()
        assertEquals(Settings.ACTION_DEVICE_INFO_SETTINGS,
            shadowOf(nonDeveloperActivity).nextStartedActivity.action)
        nonDeveloperActivity.findViewById<Button>(R.id.btnDismissUsbSetup).performClick()
        nonDeveloperController.pause().stop().destroy()
        val dismissed = ActivityTestHarness.build().create().start().resume()
        assertEquals(View.GONE, dismissed.get().findViewById<View>(R.id.usbSetupCard).visibility)
        dismissed.pause().stop().destroy()
    }

    @Test
    @Config(sdk = [28])
    fun activityUsesLegacySystemBarInsetsOnAndroidNine() {
        val application = RuntimeEnvironment.getApplication()
        application.getSharedPreferences("wamc_prefs", 0)
            .edit().putBoolean("auto_start", false).apply()
        val controller = ActivityTestHarness.build().create().start().resume()
        val activity = controller.get()
        assertTrue(activity.window.decorView.systemUiVisibility != 0)
        activity.findViewById<View>(R.id.mainLayout).dispatchApplyWindowInsets(
            WindowInsets::class.java.getDeclaredConstructor(android.graphics.Rect::class.java)
                .newInstance(android.graphics.Rect(1, 2, 3, 4)))
        assertTrue(activity.findViewById<View>(R.id.mainLayout).paddingTop >= 2)
        controller.pause().stop().destroy()
    }

    @Test fun cameraControllerReportsOpenFailureAndClosesCleanlyWithoutHardware() {
        val application = RuntimeEnvironment.getApplication()
        shadowOf(application).grantPermissions(Manifest.permission.CAMERA)
        val controller = CameraController(application)
        var failure: String? = null
        controller.openErrorListener = { failure = it }

        val input = Surface(SurfaceTexture(0))
        controller.open(null, input, 640, 480, null)
        assertTrue(failure?.startsWith("camera open failed") == true)
        controller.selectCamera("invalid-camera")
        controller.closeCapture()
        controller.close()
        input.release()
    }

    @Test fun cameraControllerSelectsAndSwitchesInjectedCameraInventory() {
        val cameras = listOf(
            CameraInfo("back", android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK,
                LensType.MAIN, "Back Camera"),
            CameraInfo("front", android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT,
                LensType.FRONT, "Front Camera"),
        )
        val controller = CameraController(RuntimeEnvironment.getApplication(), cameras)

        assertEquals("front", controller.activeCameraId)
        assertEquals("back" to "front", controller.cameraIds())
        assertEquals(false, controller.facingBack)
        controller.switchCamera()
        assertEquals("back", controller.activeCameraId)
        assertEquals(true, controller.facingBack)
        controller.switchCamera()
        assertEquals("front", controller.activeCameraId)
        controller.selectCamera("missing")
        assertEquals("front", controller.activeCameraId)
        controller.close()
    }

    @Test fun cameraControllerHandlesAsyncDisconnectAndStaleCallbacks() {
        val application = RuntimeEnvironment.getApplication()
        var error: String? = null
        val errorDevice = FakeCameraDevice()
        val errorController = CameraController(application, emptyList(), CameraOpener { _, callback, _ ->
            callback.onError(errorDevice, 7)
        })
        errorController.openErrorListener = { error = it }
        errorController.open(null, Surface(SurfaceTexture(0)), 640, 480, null)
        assertEquals("camera device error 7", error)
        assertEquals(true, errorDevice.isClosed)
        errorController.close()

        var callback: android.hardware.camera2.CameraDevice.StateCallback? = null
        var staleError: String? = null
        val staleController = CameraController(application, emptyList(), CameraOpener { _, state, _ ->
            callback = state
        })
        staleController.openErrorListener = { staleError = it }
        staleController.open(null, Surface(SurfaceTexture(0)), 640, 480, null)
        staleController.closeCapture()
        val staleDevice = FakeCameraDevice()
        callback!!.onDisconnected(staleDevice)
        assertEquals(null, staleError)
        assertEquals(true, staleDevice.isClosed)
        staleController.close()
    }

    @Test fun cameraControllerSeparatesCaptureFailureFromRotationFallback() {
        val application = RuntimeEnvironment.getApplication()
        val ordinaryDevice = FakeCameraDevice()
        var captureError: String? = null
        var rotationRejection: String? = null
        val ordinary = CameraController(application, emptyList(), CameraOpener { _, callback, _ ->
            callback.onOpened(ordinaryDevice)
        })
        ordinary.openErrorListener = { captureError = it }
        ordinary.rotationRejectedListener = { rotationRejection = it }
        ordinary.open(null, Surface(SurfaceTexture(0)), 640, 480, null)
        assertEquals("camera session configure failed", captureError)
        assertEquals(null, rotationRejection)
        ordinary.close()

        val rotateDevice = FakeCameraDevice()
        var rotateError: String? = null
        val rotate = CameraController(application, emptyList(), CameraOpener { _, callback, _ ->
            callback.onOpened(rotateDevice)
        })
        rotate.openErrorListener = { rotateError = it }
        rotate.rotationRejectedListener = { rotationRejection = it }
        rotate.open(null, Surface(SurfaceTexture(0)), 640, 480, halRotateMode = 1)
        assertEquals(null, rotateError)
        assertEquals("0", rotationRejection)
        rotate.close()
    }

    @Test fun cameraControllerClosesDeviceWhenSessionSetupThrows() {
        val device = FakeCameraDevice(IllegalStateException("surface abandoned"))
        var error: String? = null
        val controller = CameraController(
            RuntimeEnvironment.getApplication(), emptyList(), CameraOpener { _, callback, _ ->
                callback.onOpened(device)
            },
        )
        controller.openErrorListener = { error = it }
        controller.open(null, Surface(SurfaceTexture(0)), 640, 480, null)
        assertEquals("camera configure failed: surface abandoned", error)
        assertEquals(true, device.isClosed)
        controller.close()
    }

    @Test fun cameraControllerClosesFailedCaptureSessionAndReportsRequestError() {
        val device = FakeCameraDevice(true, IllegalStateException("request unsupported"))
        var error: String? = null
        val controller = CameraController(
            RuntimeEnvironment.getApplication(), emptyList(), CameraOpener { _, callback, _ ->
                callback.onOpened(device)
            },
        )
        controller.openErrorListener = { error = it }
        controller.open(null, Surface(SurfaceTexture(0)), 640, 480, null)
        assertEquals("camera capture failed: request unsupported", error)
        assertEquals(true, device.lastSession.isClosed)
        controller.close()
    }

    @Test fun serviceControlCommandsUpdateQueuedStateAndPreferences() {
        val application = RuntimeEnvironment.getApplication()
        val controller = Robolectric.buildService(CameraStreamingService::class.java)
        val service = controller.create().get()

        service.handleControl(mapOf("cmd" to "hello", "codecs" to "0,1"))
        service.handleControl(mapOf(
            "cmd" to "start", "width" to "1280", "height" to "720", "fps" to "24",
            "quality" to "high", "codec" to "hevc", "bitrate" to "5000000",
            "gop" to "2", "latency" to "low", "codecs" to "0,1",
        ))
        assertEquals("Open WAMC on the phone to start the camera", service.currentStatus())
        service.handleControl(mapOf("cmd" to "requestKeyframe"))
        service.handleControl(mapOf("cmd" to "setCamera", "cameraId" to "saved-camera"))
        assertEquals("saved-camera", application.getSharedPreferences("wamc_prefs", 0)
            .getString("selected_camera_id", null))
        service.handleControl(mapOf("cmd" to "setRotation", "rotation" to "7"))
        assertEquals(3, service.rotationQuarterTurns)
        service.handleControl(mapOf("cmd" to "rotate"))
        assertEquals(0, service.rotationQuarterTurns)
        service.handleControl(mapOf("cmd" to "setFacing", "facing" to "back"))
        service.handleControl(mapOf("cmd" to "setFacing", "facing" to "front"))
        service.handleControl(mapOf("cmd" to "ping"))
        service.handleControl(mapOf("cmd" to "unknown"))
        service.handleControl(mapOf("cmd" to "stop"))
        assertEquals("Not streaming", service.currentStatus())
        service.notifyConfigurationChanged()
        shadowOf(android.os.Looper.getMainLooper()).idleFor(500, TimeUnit.MILLISECONDS)
        service.connectAccessory()
        controller.destroy()
    }

    @Test fun installationBlocksDirectRemoteAndPendingServiceStarts() {
        val application = RuntimeEnvironment.getApplication()
        val updater = com.androidwebcam.app.update.AndroidUpdates.get(application)
        val controller = Robolectric.buildService(CameraStreamingService::class.java)
        val service = controller.create().get()
        try {
            // A hidden start normally queues until the activity resumes.
            assertFalse(service.startStreaming(640, 480))
            updater.installationResult("Pending installation", finished = false)
            service.setActivityVisible(true)
            assertFalse(service.startPendingRequest())
            assertFalse(service.streaming)
            assertFalse(service.hasCameraError)
            assertFalse(service.startStreaming(640, 480))
            service.handleControl(mapOf("cmd" to "start"))
            assertFalse(service.streaming)
            assertFalse(service.hasCameraError)
            service.setActivityVisible(false)
            service.handleControl(mapOf("cmd" to "start"))
            updater.installationResult("Installation cancelled")
            // Installation-blocked starts must not become a stale queued start.
            service.setActivityVisible(true)
            assertFalse(service.startPendingRequest())
            assertFalse(service.hasCameraError)
            // Outside installation, hidden starts retain their existing queue behavior.
            service.setActivityVisible(false)
            service.handleControl(mapOf("cmd" to "start"))
            assertTrue(service.currentStatus().contains("Open WAMC"))
        } finally {
            updater.installationResult("Finished")
            controller.destroy()
        }
    }

    @Test fun serviceWithoutCameraPermissionContainsForegroundStartDenial() {
        val application = RuntimeEnvironment.getApplication()
        shadowOf(application).denyPermissions(Manifest.permission.CAMERA)
        val controller = Robolectric.buildService(CameraStreamingService::class.java)
        val service = controller.create().get()

        assertEquals(android.app.Service.START_STICKY,
            service.onStartCommand(Intent(), 0, 1))
        service.setActivityVisible(true)
        assertEquals(false, service.startStreaming(640, 480))
        assertTrue(service.hasCameraError)
        assertTrue(service.currentStatus().isNotEmpty())
        service.stopStreaming()
        controller.destroy()
    }

    @Test fun streamingServiceInitializesAndPersistsPreferences() {
        val application = RuntimeEnvironment.getApplication()
        shadowOf(application).grantPermissions(Manifest.permission.CAMERA)

        val controller: ServiceController<CameraStreamingService> =
            Robolectric.buildService(CameraStreamingService::class.java)
        val service = controller.create().get()

        assertTrue(WamcDiscovery.isValidId(service.deviceId()))
        val binder = service.onBind(Intent(application, CameraStreamingService::class.java))
        assertEquals(service, (binder as CameraStreamingService.LocalBinder).service())
        service.setWifiDiscoveryEnabled(false)
        assertEquals(false, service.wifiDiscoveryEnabled)
        assertTrue(service.currentStatus().isNotEmpty())
        assertEquals(false, service.startStreaming(1280, 720, 30))
        assertEquals(false, service.startPendingRequest())
        service.setActivityVisible(true)
        assertEquals(false, service.startPendingRequest())
        assertTrue(service.hasCameraError)
        service.rotate()
        assertEquals(1, service.rotationQuarterTurns)
        service.setRotation(-1)
        assertEquals(3, service.rotationQuarterTurns)
        service.setEnhancementEnabled(false)
        assertEquals(false, service.enhancementEnabled)
        service.selectCamera("test-camera")
        assertEquals("test-camera", application.getSharedPreferences("wamc_prefs", 0)
            .getString("selected_camera_id", null))
        service.setQuality(StreamQuality.BALANCED)
        assertEquals(StreamQuality.BALANCED, service.currentQuality)
        service.setPreviewSurface(null)
        service.notifyConfigurationChanged()
        assertTrue(service.getAvailableCameras().isEmpty())
        assertEquals(0, service.peerCount())
        assertTrue(service.uvcGuidance().isNotEmpty())
        var discoveryChanged: Boolean? = null
        service.wifiDiscoveryChangeListener = { discoveryChanged = it }
        service.setWifiDiscoveryEnabled(true)
        assertEquals(true, discoveryChanged)
        service.setWifiDiscoveryEnabled(false)
        assertEquals(false, discoveryChanged)
        service.stopStreaming()
        assertEquals(android.app.Service.START_STICKY,
            service.onStartCommand(Intent(), 0, 1))

        controller.destroy()
    }

    @Test fun dashboardCreatesAndHandlesCameraControls() {
        val application = RuntimeEnvironment.getApplication()
        application.getSharedPreferences("wamc_prefs", 0)
            .edit().putBoolean("auto_start", false).apply()
        shadowOf(application).grantPermissions(
            Manifest.permission.CAMERA,
            Manifest.permission.POST_NOTIFICATIONS,
        )

        val controller = ActivityTestHarness.build()
            .create().start().resume()
        val activity = controller.get()
        shadowOf(android.os.Looper.getMainLooper()).idle()

        val startButton = activity.findViewById<Button>(R.id.toggle)
        assertNotNull(startButton)
        assertEquals(activity.getString(R.string.start_streaming), startButton.text.toString())
        val dashboard = activity.findViewById<DashboardLayout>(R.id.dashboard)
        measureDashboard(dashboard, 400, 600)
        measureDashboard(dashboard, 400, 1000)
        activity.resources.configuration.orientation = Configuration.ORIENTATION_LANDSCAPE
        dashboard.layoutDirection = View.LAYOUT_DIRECTION_RTL
        measureDashboard(dashboard, 1000, 500)
        dashboard.layout(0, 0, 1000, 500)
        dashboard.layoutDirection = View.LAYOUT_DIRECTION_LTR
        activity.resources.configuration.orientation = Configuration.ORIENTATION_PORTRAIT
        activity.findViewById<View>(R.id.mainLayout).dispatchApplyWindowInsets(
            WindowInsets.Builder().setInsets(WindowInsets.Type.systemBars(), Insets.of(1, 2, 3, 4)).build())
        activity.findViewById<Switch>(R.id.autoStartToggle).isChecked = false
        activity.findViewById<Switch>(R.id.wifiDiscoveryToggle).isChecked = false
        activity.findViewById<Switch>(R.id.enhanceToggle).isChecked = false
        val preferences = application.getSharedPreferences("wamc_prefs", 0)
        assertEquals(false, preferences.getBoolean("auto_start", true))
        assertEquals(false, preferences.getBoolean("wifi_discovery", true))
        assertEquals(false, startButton.isEnabled)
        startButton.performClick()
        activity.findViewById<Button>(R.id.rotate).performClick()
        activity.findViewById<Button>(R.id.switchCamera).performClick()
        activity.onRequestPermissionsResult(1, arrayOf(Manifest.permission.CAMERA),
            intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED))
        activity.onConfigurationChanged(Configuration().apply {
            orientation = Configuration.ORIENTATION_LANDSCAPE
        })
        activity.onWindowFocusChanged(true)

        controller.pause().stop().destroy()
        application.stopService(Intent(application, CameraStreamingService::class.java))
    }

    private fun measureDashboard(dashboard: DashboardLayout, width: Int, height: Int) {
        dashboard.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
        )
        dashboard.layout(0, 0, width, height)
    }
}
