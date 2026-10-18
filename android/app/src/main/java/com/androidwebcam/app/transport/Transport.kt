package com.androidwebcam.app.transport

import com.androidwebcam.app.protocol.WireProtocol
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

/**
 * Broadcasts frames to every connected transport with latest-wins queuing:
 * at most 2 pending video frames per peer; CONFIG/keyframes are kept first.
 */
class TransportHub {
    private class Peer(val out: OutputStream) {
        val queue = ArrayBlockingQueue<WireProtocol.Frame>(3)
        @Volatile var alive = true
        fun offer(frame: WireProtocol.Frame) {
            if (frame.type != WireProtocol.TYPE_VIDEO) { queue.offer(frame); return }
            while (!queue.offer(frame)) {
                val dropped = queue.poll() ?: break
                if (dropped.type == WireProtocol.TYPE_CONFIG || dropped.isKeyframe) {
                    // Never silently drop config/keyframe: put it back and drop head video.
                    if (queue.offer(dropped)) break
                }
            }
        }
    }

    private val peers = CopyOnWriteArrayList<Peer>()

    /** Fired after a peer connects so owners can send HELLO + CONFIG. */
    @Volatile var onPeerAttached: (() -> Unit)? = null

    fun attach(input: InputStream, output: OutputStream, onControl: (Map<String, String>) -> Unit) {
        val peer = Peer(output)
        peers += peer
        onPeerAttached?.invoke()
        thread(name = "awc-writer", isDaemon = true) {
            while (peer.alive) {
                val frame = runCatching { peer.queue.take() }.getOrNull() ?: break
                runCatching { WireProtocol.writeFrame(output, frame) }
                    .onFailure { peer.alive = false }
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
            }
            peer.alive = false
            peers -= peer
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
}
