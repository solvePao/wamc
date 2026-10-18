package com.androidwebcam.app

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.provider.Settings
import android.view.View
import com.androidwebcam.app.ui.MainActivity
import com.androidwebcam.app.util.UsbConfigHelper
import com.androidwebcam.app.camera.CameraStreamingService
import com.androidwebcam.app.update.AndroidRelease
import com.androidwebcam.app.update.UpdateBackend
import com.androidwebcam.app.update.UpdateCoordinator
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MainActivityPlatformCoverageTest {
    @Test fun defaultUpdateProviderUsesProcessCoordinatorWithoutStartingCheck() {
        val controller = Robolectric.buildActivity(MainActivity::class.java)
        val activity = controller.get()
        assertSame(com.androidwebcam.app.update.AndroidUpdates.get(activity), activity.updateCoordinator())
    }

    @Test fun updateMenuRequestsManualCheckAndStreamingButtonStopsAttachedService() {
        val context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("wamc_prefs", 0).edit().putBoolean("auto_start", false).apply()
        var checks = 0
        val backend = object : UpdateBackend {
            override fun latest(): AndroidRelease? { checks++; return null }
            override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File =
                error("No update offered")
            override fun install(file: File, release: AndroidRelease) = error("No update offered")
        }
        val updater = UpdateCoordinator(backend, Executor { it.run() }) { it() }
        val controller = ActivityTestHarness.build()
        controller.get().updateCoordinator = { updater }
        controller.get().configureUsb = { false }
        val serviceController = Robolectric.buildService(CameraStreamingService::class.java).create()
        try {
            val activity = controller.create().start().resume().get()
            val launchChecks = checks
            activity.findViewById<View>(R.id.updateMenu).performClick()
            val menu = org.robolectric.shadows.ShadowPopupMenu.getLatestPopupMenu()
            assertTrue(menu.menu.performIdentifierAction(menu.menu.getItem(0).itemId, 0))
            assertEquals(launchChecks + 1, checks)
            menu.dismiss()

            val service = serviceController.get()
            CameraStreamingService::class.java.getDeclaredField("streaming").apply {
                isAccessible = true
            }.setBoolean(service, true)
            val connection = MainActivity::class.java.getDeclaredField("connection").apply {
                isAccessible = true
            }.get(activity) as ServiceConnection
            connection.onServiceConnected(ComponentName(context, CameraStreamingService::class.java),
                service.onBind(Intent(context, CameraStreamingService::class.java)))
            assertTrue(service.streaming)
            activity.findViewById<View>(R.id.toggle).performClick()
            assertFalse(service.streaming)
        } finally {
            controller.pause().stop().destroy()
            serviceController.destroy()
        }
    }

    @Test fun successfulRootConfigurationDismissesSetupAndPersistsDecision() {
        val context = RuntimeEnvironment.getApplication()
        UsbConfigHelper.setSetupDismissed(context, false)
        val controller = ActivityTestHarness.build()
        controller.get().configureUsb = { true }
        try {
            val activity = controller.create().start().resume().get()
            assertEquals(View.GONE, activity.findViewById<View>(R.id.usbSetupCard).visibility)
            assertTrue(UsbConfigHelper.isSetupDismissed(activity))
        } finally { controller.pause().stop().destroy() }
    }

    @Test fun missingSpecificSettingsScreensFallBackToSystemSettings() {
        val context = RuntimeEnvironment.getApplication()
        for (developerOptions in listOf(false, true)) {
            UsbConfigHelper.setSetupDismissed(context, false)
            Settings.Global.putInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                if (developerOptions) 1 else 0)
            val controller = ActivityTestHarness.build()
            val actions = mutableListOf<String>()
            controller.get().configureUsb = { false }
            controller.get().launchUsbSettings = { intent ->
                actions.add(intent.action!!)
                if (intent.action != Settings.ACTION_SETTINGS) throw ActivityNotFoundException("missing settings screen")
            }
            try {
                val activity = controller.create().start().resume().get()
                activity.findViewById<View>(R.id.btnConfigureUsb).performClick()
                assertEquals(listOf(if (developerOptions) Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
                                   else Settings.ACTION_DEVICE_INFO_SETTINGS, Settings.ACTION_SETTINGS), actions)
                assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.usbSetupCard).visibility)
            } finally { controller.pause().stop().destroy() }
        }
    }
}
