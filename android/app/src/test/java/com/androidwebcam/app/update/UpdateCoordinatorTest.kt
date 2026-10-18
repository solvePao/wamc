package com.androidwebcam.app.update

import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class UpdateCoordinatorTest {
    private val release = AndroidRelease("0.2.1", 5, "WAMC.apk", 3, "a".repeat(64), "https://example.com")
    private class Queue : Executor {
        val tasks = mutableListOf<Runnable>()
        override fun execute(task: Runnable) { tasks.add(task) }
        fun run() { tasks.removeAt(0).run() }
    }
    private inner class Backend : UpdateBackend {
        var checks = 0
        var failure = false
        var available: AndroidRelease? = release
        var installed = false
        val file = File.createTempFile("update-test", ".apk")
        override fun latest(): AndroidRelease? { checks++; if (failure) error("offline"); return available }
        override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File {
            check(!cancelled.get()) { "cancelled" }; if (failure) error("download failed"); progress(50); return file
        }
        override fun install(file: File, release: AndroidRelease) { if (failure) error("install failed"); installed = true }
    }
    @Test fun launchChecksOnceAndManualCheckCanRepeat() {
        val backend = Backend(); val queue = Queue(); val updater = UpdateCoordinator(backend, queue) { it() }
        val states = mutableListOf<UpdateState>(); updater.listener = { states.add(it) }
        updater.download(); updater.install(); updater.check(); updater.check(); queue.run()
        assertEquals(1, backend.checks); assertTrue(updater.state is UpdateState.Available)
        updater.check(); assertEquals(0, queue.tasks.size)
        updater.check(true); queue.run(); assertEquals(2, backend.checks)
        updater.download(); updater.check(true); assertEquals(1, queue.tasks.size); queue.run()
        assertTrue(updater.state is UpdateState.Ready)
        updater.check(true); assertEquals(0, queue.tasks.size)
        updater.install(); queue.run(); assertTrue(backend.installed); assertFalse(backend.file.exists())
        updater.installationResult("done"); assertEquals(UpdateState.Message("done"), updater.state)
        updater.dismiss(); assertEquals(UpdateState.Idle, updater.state)
        assertTrue(states.any { it == UpdateState.Downloading(50) })
    }
    @Test fun absenceAndFailuresAreQuietForLaunchAndVisibleForManual() {
        val backend = Backend(); val queue = Queue(); val updater = UpdateCoordinator(backend, queue) { it() }
        backend.available = null; updater.check(); queue.run(); assertEquals(UpdateState.Idle, updater.state)
        updater.check(true); queue.run(); assertEquals(UpdateState.Message("WAMC is up to date."), updater.state)
        backend.failure = true; updater.check(true); queue.run(); assertEquals(UpdateState.Message("offline"), updater.state)
        val quiet = UpdateCoordinator(backend, queue) { it() }; quiet.check(); queue.run(); assertEquals(UpdateState.Idle, quiet.state)
    }
    @Test fun cancellationDiscardsStaleCheckAndDownload() {
        val backend = Backend(); val queue = Queue(); val updater = UpdateCoordinator(backend, queue) { it() }
        updater.check(); updater.dismiss(); queue.run(); assertEquals(UpdateState.Idle, updater.state)
        updater.check(true); queue.run(); updater.download(); updater.dismiss(); queue.run(); assertEquals(UpdateState.Idle, updater.state)
        updater.check(true); queue.run(); backend.failure = true; updater.download(); queue.run()
        assertEquals(UpdateState.Message("download failed"), updater.state)
        backend.failure = false; updater.check(true); queue.run(); updater.download(); queue.run()
        backend.failure = true; updater.install(); queue.run(); assertEquals(UpdateState.Message("install failed"), updater.state)
    }
    @Test fun readyDismissDeletesDownloadAndDetachedListenerReceivesCurrentState() {
        val backend = Backend(); val queue = Queue(); val updater = UpdateCoordinator(backend, queue) { it() }
        updater.check(); queue.run(); updater.download(); queue.run()
        var seen: UpdateState? = null; updater.listener = { seen = it }; assertTrue(seen is UpdateState.Ready)
        updater.listener = null; updater.dismiss(); assertFalse(backend.file.exists())
    }
}
