package com.androidwebcam.app.transport

import com.androidwebcam.app.util.AppLog
import java.net.ServerSocket
import kotlin.concurrent.thread

/** Phase 1/2 transport: listens on TCP 27183, reached via `adb forward`. */
class AdbSocketTransport(
    private val hub: TransportHub,
    private val port: Int = 27183,
    private val serverFactory: (Int) -> ServerSocket = { ServerSocket(it) },
) : Transport {
    override val name = "adb-tcp"
    @Volatile private var running = false
    private var server: ServerSocket? = null
    private var startGeneration = 0

    @Synchronized
    override fun start(onControl: (Map<String, String>) -> Unit) {
        if (running) return
        running = true
        val generation = ++startGeneration
        thread(name = "awc-adb-accept", isDaemon = true) {
            runCatching {
                serverFactory(port).also { listener ->
                    synchronized(this@AdbSocketTransport) {
                        if (!running || generation != startGeneration) {
                            listener.close()
                            return@thread
                        }
                        server = listener
                    }
                }.use { socket ->
                    AppLog.info("AdbSocketTransport", "listening on port $port")
                    while (running) {
                        val client = socket.accept()
                        client.tcpNoDelay = true
                        // adb-forwarded USB peers arrive via loopback; direct
                        // Wi-Fi peers do not. Wi-Fi gets the shallow queue and
                        // a small send buffer so stale frames drop at the hub
                        // (CONFIG/keyframe-aware) instead of in the kernel.
                        val lowLatency = !client.inetAddress.isLoopbackAddress
                        if (lowLatency) {
                            runCatching {
                                client.sendBufferSize = TransportHub.wifiSendBufferBytes
                            }.onFailure { AppLog.warning("AdbSocketTransport", "could not tune Wi-Fi send buffer", it) }
                        }
                        AppLog.info("AdbSocketTransport", "peer attached lowLatency=$lowLatency from ${client.inetAddress}")
                        hub.attach(
                            client.getInputStream(), client.getOutputStream(),
                            onControl, lowLatency = lowLatency)
                    }
                }
            }.onFailure { AppLog.error("AdbSocketTransport", "listener failed on port $port", it) }
        }
    }

    @Synchronized
    override fun close() {
        running = false
        runCatching { server?.close() }
            .onFailure { AppLog.warning("AdbSocketTransport", "listener close failed", it) }
        server = null
    }
}
