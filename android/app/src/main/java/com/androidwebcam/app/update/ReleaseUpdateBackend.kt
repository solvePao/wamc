package com.androidwebcam.app.update

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

interface UpdateReleaseSource {
    fun latest(installedBuild: Long, sdk: Int): AndroidRelease?
    fun download(release: AndroidRelease, target: File, cancelled: AtomicBoolean, progress: (Int) -> Unit)
}

interface UpdatePackageInstaller {
    fun validate(file: File, release: AndroidRelease)
    fun install(file: File, release: AndroidRelease)
}

/** Owns downloaded files until validation succeeds and the coordinator takes over. */
internal class ReleaseUpdateBackend(
    private val cacheDirectory: File,
    private val source: UpdateReleaseSource,
    private val installer: UpdatePackageInstaller,
    private val installedBuild: Long,
    private val sdk: Int,
) : UpdateBackend {
    override fun latest() = source.latest(installedBuild, sdk)

    override fun download(release: AndroidRelease, cancelled: AtomicBoolean, progress: (Int) -> Unit): File {
        val file = File.createTempFile("wamc-update-", ".apk", cacheDirectory)
        try {
            source.download(release, file, cancelled, progress)
            installer.validate(file, release)
            return file
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    override fun install(file: File, release: AndroidRelease) = installer.install(file, release)
}
