package com.androidwebcam.app

import com.androidwebcam.app.protocol.WireProtocol
import com.androidwebcam.app.transport.TransportHub
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Semaphore

class TransportHubTest {

    /** Blocks the writer thread mid-frame so queued content can be flushed first. */
    private class GatedOutputStream : OutputStream() {
        val enteredWrite = CountDownLatch(1)
        val release = CountDownLatch(1)
        val bytes = ByteArrayOutputStream()
        val flushed = Semaphore(0)
        override fun flush() { flushed.release() }
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

        try {
            val config = WireProtocol.encodeConfig(
                byteArrayOf(0x67), byteArrayOf(0x68), 1280, 720, 30, 0)
            hub.sendConfig(config)
            assertTrue(out.enteredWrite.await(5, TimeUnit.SECONDS))
            hub.sendVideo(ByteArray(8) { 0x41 }, false, 1000)
            hub.sendVideo(ByteArray(8) { 0x42 }, true, 2000)
            hub.flushVideo()
            // A marker after the flush proves all earlier queued work completed.
            hub.sendHello(byteArrayOf(9))
            out.release.countDown()
            assertTrue(out.flushed.tryAcquire(2, 5, TimeUnit.SECONDS))
            val frames = ByteArrayInputStream(out.bytes.toByteArray())
            assertEquals(WireProtocol.TYPE_CONFIG, WireProtocol.readFrame(frames).type)
            assertEquals(WireProtocol.TYPE_HELLO, WireProtocol.readFrame(frames).type)
            assertEquals(0, frames.available())
        } finally {
            out.release.countDown()
            input.release.countDown()
            hub.closeAll()
        }
    }

    @Test fun wifiQueueKeepsLatestVideoAndTracksDrops() {
        val hub = TransportHub()
        val out = GatedOutputStream()
        val input = GatedInputStream()
        hub.attach(input, out, onControl = {}, lowLatency = true)
        try {
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
            // Reader EOF detaches the peer independently of writer progress.
            // Keep input open until both the HELLO and latest video have completed.
            assertTrue(awaitCondition { hub.stats().written == 2L })
            val frames = ByteArrayInputStream(out.bytes.toByteArray())
            assertEquals(WireProtocol.TYPE_HELLO, WireProtocol.readFrame(frames).type)
            val video = WireProtocol.readFrame(frames)
            assertEquals(WireProtocol.TYPE_VIDEO, video.type)
            assertTrue(video.isKeyframe)
            assertArrayEquals(byteArrayOf(3), video.payload)

            input.release.countDown()
            assertTrue(awaitCondition { hub.peerCount() == 0 })
        } finally {
            out.release.countDown()
            input.release.countDown()
            hub.closeAll()
        }
    }

    @Test fun failedPeerWriteDetachesPeer() {
        val hub = TransportHub()
        val input = GatedInputStream()
        hub.attach(input, FailingOutputStream(), onControl = {})
        try {
            hub.sendHello(byteArrayOf(1))
            assertTrue(awaitCondition { hub.peerCount() == 0 })
            assertFalse(hub.stats().written > 0L)
        } finally {
            input.release.countDown()
            hub.closeAll()
        }
    }

    @Test fun controlFramesReachListener() {
        val controlBytes = ByteArrayOutputStream().apply {
            WireProtocol.writeFrame(this, WireProtocol.Frame(WireProtocol.TYPE_CONTROL, 0, 0,
                WireProtocol.encodeControl(mapOf("cmd" to "ping"))))
        }.toByteArray()
        val received = CountDownLatch(1)
        val hub = TransportHub()
        var control: Map<String, String>? = null
        try {
            hub.attach(ByteArrayInputStream(controlBytes), ByteArrayOutputStream(), {
                control = it
                received.countDown()
            })
            assertTrue(received.await(5, TimeUnit.SECONDS))
            assertEquals(mapOf("cmd" to "ping"), control)
        } finally { hub.closeAll() }
    }

    @Test fun fullUsbQueuePreservesConfigAndReplacesControl() {
        val hub = TransportHub()
        val out = GatedOutputStream()
        val input = GatedInputStream()
        hub.attach(input, out, {})
        try {
            hub.sendHello(byteArrayOf(1))
            assertTrue(out.enteredWrite.await(5, TimeUnit.SECONDS))
            repeat(TransportHub.usbQueueCapacity) { hub.sendConfig(byteArrayOf(it.toByte())) }
            hub.sendVideo(byteArrayOf(9), false, 0)
            assertEquals(1L, hub.stats().dropped)
            // A non-video frame can evict the oldest queued frame when full.
            hub.sendConfigV2(byteArrayOf(8))
            assertEquals(2L, hub.stats().dropped)
            out.release.countDown()
            assertTrue(out.flushed.tryAcquire(4, 5, TimeUnit.SECONDS))
            val frames = ByteArrayInputStream(out.bytes.toByteArray())
            assertEquals(WireProtocol.TYPE_HELLO, WireProtocol.readFrame(frames).type)
            assertEquals(WireProtocol.TYPE_CONFIG, WireProtocol.readFrame(frames).type)
            assertEquals(WireProtocol.TYPE_CONFIG, WireProtocol.readFrame(frames).type)
            assertEquals(WireProtocol.TYPE_CONFIG2, WireProtocol.readFrame(frames).type)
        } finally {
            out.release.countDown()
            input.release.countDown()
            hub.closeAll()
        }
    }

    @Test fun sustainedWriterReportsAllCompletedFrames() {
        val hub = TransportHub()
        val input = GatedInputStream()
        val output = GatedOutputStream().apply { release.countDown() }
        hub.attach(input, output, {})
        try {
            repeat(150) {
                hub.sendHello(byteArrayOf(1))
                assertTrue(output.flushed.tryAcquire(5, TimeUnit.SECONDS))
            }
            assertTrue(awaitCondition { hub.stats().written == 150L })
            assertEquals(150L, hub.stats().offered)
            assertEquals(0L, hub.stats().dropped)
        } finally { input.release.countDown(); hub.closeAll() }
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
