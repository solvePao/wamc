package com.androidwebcam.app.transport

import android.util.Log
import java.net.ServerSocket
import kotlin.concurrent.thread

/** Phase 1/2 transport: listens on TCP 27183, reached via `adb forward`. */
class AdbSocketTransport(private val hub: TransportHub, private val port: Int = 27183) : Transport {
    override val name = "adb-tcp"
    @Volatile private var running = false
    private var server: ServerSocket? = null

    override fun start(onControl: (Map<String, String>) -> Unit) {
        if (running) return
        running = true
        thread(name = "awc-adb-accept", isDaemon = true) {
            runCatching {
                ServerSocket(port).also { server = it }.use { socket ->
                    Log.i("AWC", "adb transport listening on $port")
                    while (running) {
                        val client = socket.accept()
                        client.tcpNoDelay = true
                        hub.attach(client.getInputStream(), client.getOutputStream(), onControl)
                    }
                }
            }.onFailure { Log.e("AWC", "adb transport failed on $port", it) }
        }
    }

    override fun close() {
        running = false
        runCatching { server?.close() }
        server = null
    }
}
