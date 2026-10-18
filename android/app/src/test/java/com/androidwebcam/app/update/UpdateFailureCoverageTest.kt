package com.androidwebcam.app.update

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.Signature
import android.widget.TextView
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlertDialog
import org.robolectric.shadows.ShadowLooper

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [27])
class UpdateFailureCoverageTest {
    @get:Rule val temporary = TemporaryFolder()
    private val release = AndroidRelease("0.2.1", 5, "WAMC.apk", 3, "a".repeat(64), "https://example.invalid")

    class UnavailableInstallerActivity : Activity() {
        override fun startActivity(intent: Intent) { throw ActivityNotFoundException("No installer UI") }
    }

    @Test fun missingInstallerApprovalAndSettingsProduceRetryableMessages() {
        val activityController = Robolectric.buildActivity(UnavailableInstallerActivity::class.java).setup()
        val activity = activityController.get()
        val file = temporary.newFile("update.apk")
        val backend = object : UpdateBackend {
            override fun latest() = release
            override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit) = file
            override fun install(file: File, release: AndroidRelease) = fail("Permission must precede installation")
        }
        val coordinator = UpdateCoordinator(backend, Executor { it.run() }) { it() }
        val presenter = UpdatePresenter(activity, coordinator)
        try {
            shadowOf(activity.packageManager).setCanRequestPackageInstalls(false)
            presenter.resume()
            ShadowAlertDialog.getLatestAlertDialog().getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            ShadowLooper.idleMainLooper()
            presenter.streamingChanged(false)
            ShadowAlertDialog.getLatestAlertDialog().getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            ShadowLooper.idleMainLooper()
            assertEquals(UpdateState.Message("Installation settings could not open."), coordinator.state)

            AndroidUpdates.confirmation = Intent("unavailable.installer")
            coordinator.installationResult("approval", finished = false)
            assertNull(AndroidUpdates.confirmation)
            assertFalse(coordinator.installationInProgress)
            assertEquals(UpdateState.Message("Android's installer could not open. Retry the update."), coordinator.state)
        } finally {
            AndroidUpdates.confirmation = null
            presenter.pause()
            activityController.pause().stop().destroy()
        }
    }

    @Test fun downloadProgressUpdatesExistingDialogAndPermissionCanBeDeferred() {
        val activityController = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = activityController.get()
        val file = temporary.newFile("progress.apk")
        val tasks = mutableListOf<Runnable>()
        val backend = object : UpdateBackend {
            override fun latest() = release
            override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File {
                progress(25)
                val dialog = ShadowAlertDialog.getLatestAlertDialog()
                progress(75)
                assertSame(dialog, ShadowAlertDialog.getLatestAlertDialog())
                assertEquals("Downloading update: 75%", dialog.findViewById<TextView>(android.R.id.message).text.toString())
                return file
            }
            override fun install(file: File, release: AndroidRelease) = fail("Permission must precede installation")
        }
        val coordinator = UpdateCoordinator(backend, Executor { tasks.add(it) }) { it() }
        val presenter = UpdatePresenter(activity, coordinator)
        try {
            shadowOf(activity.packageManager).setCanRequestPackageInstalls(false)
            presenter.resume()
            tasks.removeAt(0).run()
            ShadowAlertDialog.getLatestAlertDialog().getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            ShadowLooper.idleMainLooper()
            tasks.removeAt(0).run()
            presenter.streamingChanged(false)
            ShadowAlertDialog.getLatestAlertDialog().getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            ShadowLooper.idleMainLooper()
            assertEquals(UpdateState.Idle, coordinator.state)
            assertFalse(file.exists())
        } finally {
            presenter.pause()
            activityController.pause().stop().destroy()
        }
    }

    @Suppress("DEPRECATION")
    @Test fun unreadableValidatedApkAbandonsInstallerSession() {
        val context = RuntimeEnvironment.getApplication()
        val manager = shadowOf(context.packageManager)
        fun packageInfo(code: Int) = PackageInfo().apply {
            packageName = context.packageName
            versionCode = code
            versionName = "0.2.1"
            signatures = arrayOf(Signature("1234"))
        }
        manager.addPackage(packageInfo(4))
        val missing = File(temporary.root, "missing.apk")
        manager.setPackageArchiveInfo(missing.absolutePath, packageInfo(5))
        manager.setCanRequestPackageInstalls(true)

        assertThrows(FileNotFoundException::class.java) { AndroidUpdateInstaller(context).install(missing, release) }

        assertTrue(context.packageManager.packageInstaller.mySessions.isEmpty())
    }
}
