package com.androidwebcam.app

import android.content.Intent
import com.androidwebcam.app.ui.MainActivity
import com.androidwebcam.app.update.AndroidRelease
import com.androidwebcam.app.update.UpdateBackend
import com.androidwebcam.app.update.UpdateCoordinator
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import org.robolectric.Robolectric
import org.robolectric.android.controller.ActivityController

/** Keeps activity lifecycle tests independent of the release server and background executors. */
internal object ActivityTestHarness {
    fun build(intent: Intent? = null): ActivityController<MainActivity> {
        val backend = object : UpdateBackend {
            override fun latest(): AndroidRelease? = null
            override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File =
                error("No update offered by activity fixture")
            override fun install(file: File, release: AndroidRelease) = error("No update offered by activity fixture")
        }
        val coordinator = UpdateCoordinator(backend, Executor { it.run() }) { it() }
        val controller = if (intent == null) Robolectric.buildActivity(MainActivity::class.java)
            else Robolectric.buildActivity(MainActivity::class.java, intent)
        controller.get().updateCoordinator = { coordinator }
        return controller
    }
}
