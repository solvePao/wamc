package com.androidwebcam.app.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import java.io.File

class AndroidUpdateInstaller(private val context: Context) : UpdatePackageInstaller {
    @Suppress("DEPRECATION")
    override fun validate(file: File, release: AndroidRelease) {
        val manager = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val installed = manager.getPackageInfo(context.packageName, flags)
        val archive = manager.getPackageArchiveInfo(file.absolutePath, flags) ?: error("Invalid APK")
        require(archive.packageName == context.packageName) { "APK package does not match WAMC" }
        val version = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        val installedVersion = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        require(version == release.build && version > installedVersion && archive.versionName == release.version) { "APK version mismatch" }
        val expected = signatures(installed)
        require(expected.isNotEmpty() && signatures(archive) == expected) { "APK signing certificate does not match installed WAMC" }
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val certificates = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return certificates.orEmpty().map { it.toCharsString() }.toSet()
    }

    override fun install(file: File, release: AndroidRelease) {
        validate(file, release)
        check(context.packageManager.canRequestPackageInstalls()) { "Allow WAMC to install updates in Android settings" }
        val installer = context.packageManager.packageInstaller
        val parameters = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(parameters)
        try {
            installer.openSession(id).use { session ->
                file.inputStream().use { input -> session.openWrite("update.apk", 0, file.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                } }
                val result = Intent(context, UpdateInstallReceiver::class.java)
                val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val callback = PendingIntent.getBroadcast(context, id, result, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
                session.commit(callback.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(id)
            throw error
        }
    }
}
