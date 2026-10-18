package com.androidwebcam.app

import com.androidwebcam.app.protocol.WireProtocol
import com.androidwebcam.app.transport.TransportHub
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class TransportHubTest {

    /** Blocks the writer thread mid-frame so queued content can be flushed first. */
    private class GatedOutputStream : OutputStream() {
        val enteredWrite = CountDownLatch(1)
        val release = CountDownLatch(1)
        val bytes = ByteArrayOutputStream()
        override fun write(b: Int) {
            enteredWrite.countDown()
            release.await(15, TimeUnit.SECONDS)
            bytes.write(b)
        }
    }

    /** Parks the reader thread so the peer stays attached for the test. */
    private class GatedInputStream : InputStream() {
        val release = CountDownLatch(1)
        override fun read(): Int {
            release.await(15, TimeUnit.SECONDS)
            return -1
        }
    }

    private class FailingOutputStream : OutputStream() {
        override fun write(b: Int) {
            throw IOException("peer closed")
        }
    }

    @Test fun flushVideoDropsStaleFramesButKeepsConfig() {
        val hub = TransportHub()
        val out = GatedOutputStream()
        val input = GatedInputStream()
        hub.attach(input, out, onControl = {}, lowLatency = false)

        val config = WireProtocol.encodeConfig(
            byteArrayOf(0x67), byteArrayOf(0x68), 1280, 720, 30, 0)
        hub.sendConfig(config)
        assertEquals(true, out.enteredWrite.await(5, TimeUnit.SECONDS))

        hub.sendVideo(ByteArray(8) { 0x41 }, false, 1000)
        hub.sendVideo(ByteArray(8) { 0x42 }, true, 2000)
        Thread.sleep(200)
        hub.flushVideo()
        out.release.countDown()
        input.release.countDown()

        val expected = WireProtocol.HEADER_SIZE + config.size
        val deadline = System.currentTimeMillis() + 5000
        while (out.bytes.size() < expected && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertEquals(expected, out.bytes.size())
        Thread.sleep(300)
        assertEquals(expected, out.bytes.size())
        assertEquals(WireProtocol.TYPE_CONFIG, out.bytes.toByteArray()[4].toInt())
    }

    @Test fun wifiQueueKeepsLatestVideoAndTracksDrops() {
        val hub = TransportHub()
        val out = GatedOutputStream()
        val input = GatedInputStream()
        hub.attach(input, out, onControl = {}, lowLatency = true)
        hub.sendHello(byteArrayOf(1))
        assertTrue(out.enteredWrite.await(5, TimeUnit.SECONDS))

        hub.sendVideo(byteArrayOf(1), false, 1)
        hub.sendVideo(byteArrayOf(2), false, 2)
        hub.sendVideo(byteArrayOf(3), true, 3)

        val stats = hub.stats()
        assertEquals(4L, stats.offered)
        assertEquals(2L, stats.dropped)
        assertEquals(0L, stats.written)

        out.release.countDown()
        input.release.countDown()
        assertTrue(awaitCondition { hub.peerCount() == 0 })
        assertTrue(hub.stats().written >= 1L)
    }

    @Test fun failedPeerWriteDetachesPeer() {
        val hub = TransportHub()
        val input = GatedInputStream()
        hub.attach(input, FailingOutputStream(), onControl = {})
        hub.sendHello(byteArrayOf(1))

        assertTrue(awaitCondition { hub.peerCount() == 0 })
        input.release.countDown()
        assertFalse(hub.stats().written > 0L)
    }

    private fun awaitCondition(timeoutMs: Long = 5_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(10)
        }
        return condition()
    }
}
