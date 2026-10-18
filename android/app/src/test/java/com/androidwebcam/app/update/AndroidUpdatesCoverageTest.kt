package com.androidwebcam.app.update

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AndroidUpdatesCoverageTest {
    @get:Rule val temporary = TemporaryFolder()
    private val release = AndroidRelease("0.3.0", 10, "WAMC.apk", 3, "a".repeat(64), "https://example.invalid")

    private class Source(private val release: AndroidRelease) : UpdateReleaseSource {
        var requestedBuild: Long? = null
        var requestedSdk: Int? = null
        var failure: Exception? = null
        var target: File? = null
        var cancellation: AtomicBoolean? = null

        override fun latest(installedBuild: Long, sdk: Int): AndroidRelease {
            requestedBuild = installedBuild
            requestedSdk = sdk
            return release
        }

        override fun download(release: AndroidRelease, target: File, cancelled: AtomicBoolean, progress: (Int) -> Unit) {
            this.target = target
            cancellation = cancelled
            target.writeBytes(byteArrayOf(1, 2, 3))
            failure?.let { throw it }
            progress(100)
        }
    }

    private class Installer : UpdatePackageInstaller {
        var validated: Pair<File, AndroidRelease>? = null
        var installed: Pair<File, AndroidRelease>? = null
        var failure: Exception? = null
        override fun validate(file: File, release: AndroidRelease) {
            validated = file to release
            failure?.let { throw it }
        }
        override fun install(file: File, release: AndroidRelease) { installed = file to release }
    }

    @Test fun backendForwardsCompatibilityAndTransfersOnlyValidatedDownloads() {
        val source = Source(release)
        val installer = Installer()
        val backend = ReleaseUpdateBackend(temporary.root, source, installer, 4, 35)
        assertSame(release, backend.latest())
        assertEquals(4L, source.requestedBuild)
        assertEquals(35, source.requestedSdk)
        val cancelled = AtomicBoolean(false)
        val progress = mutableListOf<Int>()
        val file = backend.download(release, cancelled, progress::add)
        assertSame(cancelled, source.cancellation)
        assertArrayEquals(byteArrayOf(1, 2, 3), file.readBytes())
        assertEquals(listOf(100), progress)
        assertEquals(file to release, installer.validated)
        backend.install(file, release)
        assertEquals(file to release, installer.installed)
        assertTrue("Coordinator owns cleanup after backend returns", file.exists())
    }

    @Test fun failedDownloadDeletesPartialFileAndPreservesFailure() {
        val source = Source(release)
        val installer = Installer()
        val failure = IllegalStateException("connection closed")
        source.failure = failure
        val backend = ReleaseUpdateBackend(temporary.root, source, installer, 4, 35)
        val actual = assertThrows(IllegalStateException::class.java) {
            backend.download(release, AtomicBoolean(false)) { fail("Incomplete download reports no completion") }
        }
        assertSame(failure, actual)
        assertFalse(source.target!!.exists())
        assertNull(installer.validated)
    }

    @Test fun failedValidationDeletesDownloadedFileBeforeReportingFailure() {
        val source = Source(release)
        val installer = Installer()
        val failure = IllegalArgumentException("certificate mismatch")
        installer.failure = failure
        val backend = ReleaseUpdateBackend(temporary.root, source, installer, 4, 35)
        val actual = assertThrows(IllegalArgumentException::class.java) {
            backend.download(release, AtomicBoolean(false)) {}
        }
        assertSame(failure, actual)
        assertNotNull(installer.validated)
        assertFalse(source.target!!.exists())
        assertNull(installer.installed)
    }
}
