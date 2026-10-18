package com.androidwebcam.app

import com.androidwebcam.app.transport.AdbSocketTransport
import com.androidwebcam.app.transport.TransportHub
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket

class AdbSocketTransportTest {
    @Test fun listenerBindFailureIsContainedAndCloseIsSafe() {
        ServerSocket(0).use { occupied ->
            val hub = TransportHub()
            val transport = AdbSocketTransport(hub, occupied.localPort)
            transport.start {}
            transport.start {} // repeated starts do not spawn another listener

            val deadline = System.nanoTime() + 2_000_000_000L
            while (System.nanoTime() < deadline && listenerThreadAlive()) {
                Thread.sleep(10)
            }

            assertFalse(listenerThreadAlive())
            transport.close()
            transport.close()
            hub.closeAll()
        }
    }

    @Test fun listenerAcceptsLoopbackPeerAndCloses() {
        val port = ServerSocket(0).use { it.localPort }
        val hub = TransportHub()
        val transport = AdbSocketTransport(hub, port)
        transport.start {}

        val deadline = System.nanoTime() + 2_000_000_000L
        var connected = false
        while (System.nanoTime() < deadline && !connected) {
            try {
                java.net.Socket("127.0.0.1", port).use { connected = true }
            } catch (_: java.io.IOException) {
                Thread.sleep(10)
            }
        }

        assertTrue(connected)
        transport.close()
        hub.closeAll()
    }

    private fun listenerThreadAlive(): Boolean =
        Thread.getAllStackTraces().keys.any { it.name == "awc-adb-accept" && it.isAlive }
}
