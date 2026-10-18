package com.androidwebcam.app.update

import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

data class AndroidRelease(val version: String, val build: Long, val asset: String,
    val size: Long, val sha256: String, val downloadUrl: String)

/** Only release assets returned by the configured public repository are downloadable. */
class ReleaseRepository(private val connect: (String) -> HttpURLConnection = {
    URL(it).openConnection() as HttpURLConnection
}) : UpdateReleaseSource {
    override fun latest(installedBuild: Long, sdk: Int): AndroidRelease? {
        val release = JSONObject(readText("https://api.github.com/repos/solvePao/wamc-releases/releases/latest"))
        if (release.optBoolean("draft") || release.optBoolean("prerelease")) return null
        val tag = release.getString("tag_name")
        val assets = release.getJSONArray("assets")
        val urls = (0 until assets.length()).associate { index ->
            val asset = assets.getJSONObject(index)
            asset.getString("name") to asset.getString("browser_download_url")
        }
        val metadataUrl = urls["android-update.json"] ?: error("Release has no Android update metadata")
        requireAssetUrl(metadataUrl, tag, "android-update.json")
        return parseMetadata(readText(metadataUrl), tag, urls, installedBuild, sdk)
    }

    override fun download(release: AndroidRelease, target: File, cancelled: AtomicBoolean, progress: (Int) -> Unit) {
        val connection = connection(release.downloadUrl)
        try {
            require(connection.responseCode == 200) { "Download failed (HTTP ${connection.responseCode})" }
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            connection.inputStream.use { input -> target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    check(!cancelled.get()) { "Download cancelled" }
                    val size = input.read(buffer)
                    if (size < 0) break
                    count += size
                    require(count <= release.size) { "Download exceeds expected size" }
                    digest.update(buffer, 0, size)
                    output.write(buffer, 0, size)
                    progress((count * 100 / release.size).toInt())
                }
            } }
            require(count == release.size) { "Incomplete download" }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            require(actual == release.sha256) { "Download checksum mismatch" }
        } catch (error: Exception) {
            target.delete()
            throw error
        } finally { connection.disconnect() }
    }

    private fun readText(url: String): String {
        val connection = connection(url)
        try {
            require(connection.responseCode == 200) { "Update check failed (HTTP ${connection.responseCode})" }
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                var total = 0
                while (true) {
                    val size = input.read(buffer)
                    if (size < 0) break
                    total += size
                    require(total <= MAX_METADATA_BYTES) { "Update metadata too large" }
                    output.write(buffer, 0, size)
                }
                output.toByteArray().toString(Charsets.UTF_8)
            }
        } finally { connection.disconnect() }
    }

    private fun connection(url: String) = connect(url).apply {
        connectTimeout = 15_000
        readTimeout = 15_000
        setRequestProperty("Accept", "application/vnd.github+json")
        setRequestProperty("User-Agent", "WAMC-Android-Updater")
    }

    companion object {
        private const val MAX_METADATA_BYTES = 256 * 1024

        fun parseMetadata(text: String, tag: String, assets: Map<String, String>, installedBuild: Long, sdk: Int): AndroidRelease? {
            val metadata = JSONObject(text)
            val version = metadata.getString("version")
            require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(version) && tag == "v$version") { "Release version mismatch" }
            val build = metadata.getLong("build")
            require(build > 0) { "Invalid release build" }
            if (build <= installedBuild) return null
            val minAndroid = metadata.getInt("minAndroid")
            require(minAndroid >= 26) { "Invalid minimum Android version" }
            if (minAndroid > sdk) return null
            val asset = metadata.getString("asset")
            require(asset.endsWith(".apk") && '/' !in asset) { "Invalid APK asset" }
            val url = assets[asset] ?: error("Release APK is missing")
            requireAssetUrl(url, tag, asset)
            val size = metadata.getLong("size")
            require(size in 1..(512L * 1024 * 1024)) { "Invalid APK size" }
            val sha256 = metadata.getString("sha256").lowercase()
            require(Regex("[0-9a-f]{64}").matches(sha256)) { "Invalid APK checksum" }
            return AndroidRelease(version, build, asset, size, sha256, url)
        }

        private fun requireAssetUrl(url: String, tag: String, asset: String) {
            require(url == "https://github.com/solvePao/wamc-releases/releases/download/$tag/$asset") {
                "Release asset is outside the configured repository"
            }
        }
    }
}
