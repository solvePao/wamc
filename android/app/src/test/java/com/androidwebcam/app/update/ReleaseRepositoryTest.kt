package com.androidwebcam.app.update

import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ReleaseRepositoryTest {
    private val base = "https://github.com/solvePao/wamc-releases/releases/download/v0.2.1/"
    private val payload = "apk".toByteArray()
    private val hash = MessageDigest.getInstance("SHA-256").digest(payload).joinToString("") { "%02x".format(it) }
    private fun metadata() = JSONObject().put("version", "0.2.1").put("build", 5)
        .put("minAndroid", 26).put("asset", "WAMC.apk").put("size", 3).put("sha256", hash)
    private fun parse(json: JSONObject = metadata(), tag: String = "v0.2.1", url: String = base + "WAMC.apk", build: Long = 4, sdk: Int = 28) =
        ReleaseRepository.parseMetadata(json.toString(), tag, mapOf("WAMC.apk" to url), build, sdk)
    private class Connection(private val bytes: ByteArray, private val status: Int = 200) : HttpURLConnection(URL("https://example.com")) {
        var disconnected = false
        override fun connect() = Unit
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getInputStream() = ByteArrayInputStream(bytes)
    }
    @Test fun defaultConnectionIsConfiguredWithoutNetworkIo() {
        val repository = ReleaseRepository()
        val connection = ReleaseRepository::class.java.getDeclaredMethod("connection", String::class.java)
            .apply { isAccessible = true }.invoke(repository, "https://example.invalid/release") as HttpURLConnection
        try {
            assertEquals("example.invalid", connection.url.host)
            assertEquals(15_000, connection.connectTimeout)
            assertEquals(15_000, connection.readTimeout)
            assertEquals("WAMC-Android-Updater", connection.getRequestProperty("User-Agent"))
            assertEquals("application/vnd.github+json", connection.getRequestProperty("Accept"))
        } finally { connection.disconnect() }
    }

    @Test fun validatesReleaseAndRejectsOlderOrUnsupportedBuilds() {
        assertEquals(5L, parse()!!.build)
        assertNull(parse(build = 5)); assertNull(parse(build = 6)); assertNull(parse(sdk = 25))
        listOf(metadata().put("build", 0), metadata().put("minAndroid", 25), metadata().put("asset", "bad"),
            metadata().put("asset", "missing.apk"), metadata().put("size", 0), metadata().put("sha256", "bad"),
            metadata().put("version", "bad"), metadata().put("version", "0.2.2")).forEach { json ->
            assertThrows(Exception::class.java) { parse(json) }
        }
        assertThrows(Exception::class.java) { parse(url = "https://evil.example/WAMC.apk") }
    }
    @Test fun latestBindsMetadataAndApkToStableRelease() {
        val assets = """[{"name":"android-update.json","browser_download_url":"${base}android-update.json"},{"name":"WAMC.apk","browser_download_url":"${base}WAMC.apk"}]"""
        val release = JSONObject("""{"tag_name":"v0.2.1","assets":$assets}""")
        val repository = ReleaseRepository { url -> Connection((if (url.contains("api.github")) release.toString() else metadata().toString()).toByteArray()) }
        assertEquals("0.2.1", repository.latest(4, 28)!!.version)
        release.put("draft", true); assertNull(repository.latest(4, 28))
        release.put("draft", false).put("prerelease", true); assertNull(repository.latest(4, 28))
        release.put("prerelease", false).put("assets", org.json.JSONArray())
        assertThrows(Exception::class.java) { repository.latest(4, 28) }
    }
    @Test fun verifiesDownloadSizeChecksumAndCancellation() {
        val connection = Connection(payload)
        val repository = ReleaseRepository { connection }
        val file = File.createTempFile("update-test", ".apk")
        var progress = 0
        repository.download(parse()!!, file, AtomicBoolean(false)) { progress = it }
        assertEquals("apk", file.readText()); assertEquals(100, progress); assertTrue(connection.disconnected)
        listOf(parse()!!.copy(size = 2), parse()!!.copy(size = 4), parse()!!.copy(sha256 = "a".repeat(64))).forEach { release ->
            assertThrows(Exception::class.java) { repository.download(release, file, AtomicBoolean(false)) {} }
            assertFalse(file.exists())
        }
        assertThrows(Exception::class.java) { repository.download(parse()!!, file, AtomicBoolean(true)) {} }
        assertThrows(Exception::class.java) { ReleaseRepository { Connection(payload, 404) }.download(parse()!!, file, AtomicBoolean(false)) {} }
        assertThrows(Exception::class.java) { ReleaseRepository { Connection(payload, 403) }.latest(4, 28) }
        assertThrows(Exception::class.java) { ReleaseRepository { Connection(ByteArray(256 * 1024 + 1)) }.latest(4, 28) }
    }
}
