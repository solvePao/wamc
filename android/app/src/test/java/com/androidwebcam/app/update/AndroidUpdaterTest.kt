package com.androidwebcam.app.update

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.Signature
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlertDialog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [27])
class AndroidUpdaterTest {
    private val release = AndroidRelease("0.2.1", 5, "WAMC.apk", 3, "a".repeat(64), "https://example.com")
    private val context get() = RuntimeEnvironment.getApplication()
    private fun info(name: String = context.packageName, code: Int = 5, signature: String = "1234") = PackageInfo().apply {
        packageName = name; versionCode = code; versionName = "0.2.1"; signatures = arrayOf(Signature(signature))
    }
    @Test fun installerRejectsInvalidPackageVersionAndCertificate() {
        val manager = shadowOf(context.packageManager)
        manager.addPackage(info(code = 4))
        val file = File.createTempFile("update-test", ".apk").apply { writeText("apk") }
        val installer = AndroidUpdateInstaller(context)
        assertThrows(Exception::class.java) { installer.validate(file, release) }
        listOf(info("wrong.package"), info(code = 4), info(signature = "5678"), info().apply { versionName = "0.2.2" },
            info().apply { signatures = emptyArray() }).forEach { archive ->
            manager.setPackageArchiveInfo(file.absolutePath, archive)
            assertThrows(Exception::class.java) { installer.validate(file, release) }
        }
        manager.setPackageArchiveInfo(file.absolutePath, info())
        installer.validate(file, release)
        manager.setCanRequestPackageInstalls(false)
        assertThrows(Exception::class.java) { installer.install(file, release) }
        manager.setCanRequestPackageInstalls(true)
        installer.install(file, release)
        assertEquals(1, context.packageManager.packageInstaller.mySessions.size)
        file.delete()
    }

    private class Backend(private val release: AndroidRelease) : UpdateBackend {
        val file = File.createTempFile("update-test", ".apk")
        var installed = false
        override fun latest() = release
        override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit) = file
        override fun install(file: File, release: AndroidRelease) { installed = true }
    }
    private fun button(which: Int) {
        ShadowAlertDialog.getLatestAlertDialog().getButton(which).performClick()
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
    }

    @Test fun presenterPromptsBeforeDownloadDefersStreamingAndHandlesPermission() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        val backend = Backend(release)
        val coordinator = UpdateCoordinator(backend, Executor { it.run() }) { it() }
        val presenter = UpdatePresenter(activity, coordinator)
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(false)
        presenter.resume()
        assertTrue(coordinator.state is UpdateState.Available)
        button(AlertDialog.BUTTON_NEGATIVE); assertEquals(UpdateState.Idle, coordinator.state)
        coordinator.check(true); button(AlertDialog.BUTTON_POSITIVE)
        assertTrue(coordinator.state is UpdateState.Ready); assertFalse(backend.installed)
        presenter.streamingChanged(false)
        button(AlertDialog.BUTTON_POSITIVE)
        assertEquals("android.settings.MANAGE_UNKNOWN_APP_SOURCES", shadowOf(activity).nextStartedActivity.action)
        presenter.pause()
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(true)
        presenter.resume()
        assertTrue(backend.installed)
        button(AlertDialog.BUTTON_POSITIVE)
        presenter.pause(); controller.pause().stop().destroy()
    }
    @Test fun presenterCancelsDownloadDismissesReadyAndOpensInstallerApproval() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        val backend = Backend(release)
        val tasks = mutableListOf<Runnable>()
        val coordinator = UpdateCoordinator(backend, Executor { tasks.add(it) }) { it() }
        val presenter = UpdatePresenter(activity, coordinator)
        presenter.resume(); tasks.removeAt(0).run()
        button(AlertDialog.BUTTON_POSITIVE)
        assertTrue(coordinator.state is UpdateState.Downloading)
        button(AlertDialog.BUTTON_NEGATIVE); tasks.removeAt(0).run()
        assertEquals(UpdateState.Idle, coordinator.state)
        coordinator.check(true); tasks.removeAt(0).run(); button(AlertDialog.BUTTON_POSITIVE); tasks.removeAt(0).run()
        assertTrue(coordinator.state is UpdateState.Ready)
        button(AlertDialog.BUTTON_NEUTRAL); assertEquals(UpdateState.Idle, coordinator.state)
        assertFalse(backend.file.exists())
        AndroidUpdates.confirmation = Intent("android.intent.action.VIEW")
        coordinator.installationResult("approval", false)
        assertEquals("android.intent.action.VIEW", shadowOf(activity).nextStartedActivity.action)
        assertNull(AndroidUpdates.confirmation)
        presenter.pause(); controller.pause().stop().destroy()
    }
    @Test fun closingStreamingNoticeKeepsDownloadUntilStreamingStops() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        shadowOf(activity.packageManager).setCanRequestPackageInstalls(true)
        val backend = Backend(release)
        val coordinator = UpdateCoordinator(backend, Executor { it.run() }) { it() }
        val presenter = UpdatePresenter(activity, coordinator)
        presenter.resume()
        button(AlertDialog.BUTTON_POSITIVE)
        assertTrue(coordinator.state is UpdateState.Ready)
        val notice = ShadowAlertDialog.getLatestAlertDialog()
        button(AlertDialog.BUTTON_NEGATIVE)
        assertFalse(notice.isShowing)
        assertTrue(coordinator.state is UpdateState.Ready)
        assertTrue(backend.file.exists())
        assertFalse(backend.installed)
        presenter.streamingChanged(true)
        assertFalse(notice.isShowing)
        presenter.streamingChanged(false)
        assertTrue(backend.installed)
        assertFalse(backend.file.exists())
        presenter.pause()
        controller.pause().stop().destroy()
    }

    @Test fun receiverHandlesApprovalSuccessCancellationAndFailure() {
        val receiver = UpdateInstallReceiver()
        val updater = AndroidUpdates.get(context)
        receiver.onReceive(context, Intent().putExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_PENDING_USER_ACTION)
            .putExtra(Intent.EXTRA_INTENT, Intent("approve")))
        assertEquals("approve", AndroidUpdates.confirmation?.action)
        receiver.onReceive(context, Intent().putExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_PENDING_USER_ACTION))
        assertNull(AndroidUpdates.confirmation)
        listOf(PackageInstaller.STATUS_SUCCESS, PackageInstaller.STATUS_FAILURE_ABORTED, PackageInstaller.STATUS_FAILURE).forEach { status ->
            receiver.onReceive(context, Intent().putExtra(PackageInstaller.EXTRA_STATUS, status))
            assertTrue(updater.state is UpdateState.Message)
        }
    }
}
