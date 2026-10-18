package com.androidwebcam.app.transport

import com.androidwebcam.app.protocol.WireProtocol
import com.androidwebcam.app.util.AppLog
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/** One bidirectional AWC1 stream (TCP socket or USB accessory). */
interface Transport {
    val name: String
    fun start(onControl: (Map<String, String>) -> Unit)
    fun close()
}

/** Cumulative hub counters, for latency logging/diagnostics. */
data class HubStats(
    val offered: Long,
    val dropped: Long,
    val written: Long,
    val lastQueueWaitMs: Long,
    val lastWriteMs: Long,
    val maxQueueWaitMs: Long,
)

/**
 * Broadcasts frames to every connected transport with latest-wins queuing:
 * at most [usbQueueCapacity] pending video frames per USB peer and
 * [wifiQueueCapacity] per Wi-Fi peer; CONFIG/keyframes are kept first.
 * Wi-Fi peers get the shallow queue so staleness drops here — where
 * CONFIG/keyframes are protected — instead of hiding in kernel buffers.
 */
class TransportHub {
    private data class Queued(val frame: WireProtocol.Frame, val offeredNs: Long)

    private inner class Peer(
        val out: OutputStream,
        val lowLatency: Boolean,
    ) {
        val queue = ArrayBlockingQueue<Queued>(if (lowLatency) wifiQueueCapacity else usbQueueCapacity)
        @Volatile var alive = true
        fun offer(frame: WireProtocol.Frame) {
            recordOffered()
            val queued = Queued(frame, System.nanoTime())
            if (frame.type != WireProtocol.TYPE_VIDEO) {
                // Control/config must get through: evict the head if full.
                while (!queue.offer(queued)) {
                    if (queue.poll() == null) break
                    recordDropped()
                }
                return
            }
            while (!queue.offer(queued)) {
                val dropped = queue.poll() ?: break
                recordDropped()
                if (dropped.frame.type == WireProtocol.TYPE_CONFIG || dropped.frame.isKeyframe) {
                    // Never silently drop config/keyframe: put it back and drop head video.
                    if (queue.offer(dropped)) break
                }
            }
        }
    }

    private val peers = CopyOnWriteArrayList<Peer>()

    private val statsLock = Any()
    private var offered = 0L
    private var dropped = 0L
    private var written = 0L
    private var lastQueueWaitMs = 0L
    private var lastWriteMs = 0L
    private var maxQueueWaitMs = 0L

    private fun recordOffered() { synchronized(statsLock) { offered++ } }
    private fun recordDropped() { synchronized(statsLock) { dropped++ } }
    private fun recordWritten(queueWaitMs: Long, writeMs: Long) {
        synchronized(statsLock) {
            written++
            lastQueueWaitMs = queueWaitMs
            lastWriteMs = writeMs
            if (queueWaitMs > maxQueueWaitMs) maxQueueWaitMs = queueWaitMs
        }
    }

    fun stats(): HubStats = synchronized(statsLock) {
        HubStats(offered, dropped, written, lastQueueWaitMs, lastWriteMs, maxQueueWaitMs)
    }

    /** Fired after a peer connects so owners can send HELLO + CONFIG. */
    @Volatile var onPeerAttached: (() -> Unit)? = null

    fun attach(
        input: InputStream,
        output: OutputStream,
        onControl: (Map<String, String>) -> Unit,
        lowLatency: Boolean = false,
    ) {
        val peer = Peer(output, lowLatency)
        peers += peer
        onPeerAttached?.invoke()
        thread(name = "awc-writer", isDaemon = true) {
            var sinceLog = 0
            while (peer.alive) {
                val queued = runCatching { peer.queue.take() }
                    .onFailure { AppLog.debug("TransportHub", "writer queue interrupted: ${it.message}") }
                    .getOrNull() ?: break
                val writeStartNs = System.nanoTime()
                val ok = runCatching { WireProtocol.writeFrame(output, queued.frame) }
                    .onFailure {
                        peer.alive = false
                        AppLog.warning("TransportHub", "peer write failed lowLatency=${peer.lowLatency}", it)
                    }
                    .isSuccess
                if (!ok) break
                val nowNs = System.nanoTime()
                recordWritten(
                    queueWaitMs = (writeStartNs - queued.offeredNs) / 1_000_000,
                    writeMs = (nowNs - writeStartNs) / 1_000_000,
                )
                if (++sinceLog >= 150) {
                    sinceLog = 0
                    val s = stats()
                    AppLog.debug("TransportHub", "hub lowLatency=${peer.lowLatency} offered=${s.offered} " +
                        "dropped=${s.dropped} written=${s.written} " +
                        "qWaitLast=${s.lastQueueWaitMs}ms qWaitMax=${s.maxQueueWaitMs}ms " +
                        "writeLast=${s.lastWriteMs}ms peers=${peers.size}")
                }
            }
            peers -= peer
        }
        thread(name = "awc-reader", isDaemon = true) {
            runCatching {
                while (peer.alive) {
                    val frame = WireProtocol.readFrame(input)
                    if (frame.type == WireProtocol.TYPE_CONTROL) {
                        onControl(WireProtocol.decodeControl(frame.payload))
                    }
                }
            }.onFailure { AppLog.debug("TransportHub", "peer reader stopped: ${it.message}") }
            peer.alive = false
            peers -= peer
        }
    }

    /**
     * Drops queued VIDEO frames on every peer, keeping CONFIG / CONTROL /
     * HELLO. Call at pipeline restart before the new CONFIG so stale
     * pre-restart P-frames can never sit ahead of it in TCP order.
     */
    fun flushVideo() {
        peers.forEach { peer ->
            runCatching {
                peer.queue.removeIf { queued -> queued.frame.type == WireProtocol.TYPE_VIDEO }
            }.onFailure { AppLog.warning("TransportHub", "could not flush queued video", it) }
        }
    }

    fun sendVideo(data: ByteArray, isKeyframe: Boolean, ptsUs: Long) {
        val frame = WireProtocol.Frame(
            WireProtocol.TYPE_VIDEO,
            if (isKeyframe) WireProtocol.FLAG_KEYFRAME else 0, ptsUs, data)
        peers.forEach { it.offer(frame) }
    }

    fun sendConfig(payload: ByteArray) {
        peers.forEach { it.offer(WireProtocol.Frame(WireProtocol.TYPE_CONFIG, 0, 0, payload)) }
    }

    fun sendConfigV2(payload: ByteArray) {
        peers.forEach { it.offer(WireProtocol.Frame(WireProtocol.TYPE_CONFIG2, 0, 0, payload)) }
    }

    fun sendHello(payload: ByteArray) {
        peers.forEach { it.offer(WireProtocol.Frame(WireProtocol.TYPE_HELLO, 0, 0, payload)) }
    }

    fun peerCount(): Int = peers.size
    fun closeAll() { peers.forEach { it.alive = false }; peers.clear() }

    companion object {
        const val usbQueueCapacity = 3
        const val wifiQueueCapacity = 1
        const val wifiSendBufferBytes = 128 * 1024
    }
}
