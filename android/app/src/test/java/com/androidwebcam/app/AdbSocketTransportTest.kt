package com.androidwebcam.app

import com.androidwebcam.app.transport.AdbSocketTransport
import com.androidwebcam.app.transport.TransportHub
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class AdbSocketTransportTest {
    @Test fun listenerBindFailureIsContainedAndCloseIsSafe() {
        ServerSocket(0).use { occupied ->
            val hub = TransportHub()
            // Exercise the default Android socket adapter on an ephemeral port.
            // Service fixtures may share a host whose adb-forward port is occupied.
            val defaults = AdbSocketTransport(hub, 0)
            @Suppress("UNCHECKED_CAST")
            val defaultFactory = AdbSocketTransport::class.java.getDeclaredField("serverFactory")
                .apply { isAccessible = true }.get(defaults) as (Int) -> ServerSocket
            defaultFactory(0).use { assertTrue(it.localPort > 0) }
            val listener = AtomicReference<Thread>()
            val attempted = CountDownLatch(1)
            val transport = AdbSocketTransport(hub, occupied.localPort) { port ->
                listener.set(Thread.currentThread())
                try { ServerSocket(port) } finally { attempted.countDown() }
            }
            try {
                transport.start {}
                transport.start {} // repeated starts do not spawn another listener
                assertTrue(attempted.await(2, TimeUnit.SECONDS))
                listener.get().join(2_000)
                assertTrue(!listener.get().isAlive)
            } finally {
                transport.close()
                transport.close()
                hub.closeAll()
            }
        }
    }

    @Test fun listenerAcceptsLoopbackPeerAndCloses() {
        ServerSocket(0).use { server ->
            val hub = TransportHub()
            val attached = CountDownLatch(1)
            val listener = AtomicReference<Thread>()
            hub.onPeerAttached = { attached.countDown() }
            val transport = AdbSocketTransport(hub, server.localPort) {
                listener.set(Thread.currentThread())
                server
            }
            try {
                transport.start {}
                Socket("127.0.0.1", server.localPort).use {
                    assertTrue(attached.await(2, TimeUnit.SECONDS))
                    assertEquals(1, hub.peerCount())
                }
            } finally {
                transport.close()
                listener.get()?.join(2_000)
                hub.closeAll()
            }
            assertTrue(server.isClosed)
            assertTrue(!listener.get().isAlive)
        }
    }
    @Test fun closeWhileBindingClosesLateServer() {
        val server = ServerSocket(0)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val listener = AtomicReference<Thread>()
        val hub = TransportHub()
        val transport = AdbSocketTransport(hub, 0) {
            listener.set(Thread.currentThread())
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
            server
        }
        try {
            transport.start {}
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            transport.close()
            release.countDown()
            listener.get().join(2_000)
            assertTrue(!listener.get().isAlive)
            assertTrue(server.isClosed)
            assertEquals(0, hub.peerCount())
        } finally { release.countDown(); transport.close(); server.close(); hub.closeAll() }
    }

    @Test fun oldBindingCannotReplaceRestartedListener() {
        val oldServer = ServerSocket(0)
        val newServer = ServerSocket(0)
        val oldEntered = CountDownLatch(1)
        val releaseOld = CountDownLatch(1)
        val attached = CountDownLatch(1)
        val oldThread = AtomicReference<Thread>()
        val newThread = AtomicReference<Thread>()
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val hub = TransportHub().apply { onPeerAttached = { attached.countDown() } }
        val transport = AdbSocketTransport(hub, 0) {
            if (attempts.getAndIncrement() == 0) {
                oldThread.set(Thread.currentThread())
                oldEntered.countDown()
                check(releaseOld.await(5, TimeUnit.SECONDS))
                oldServer
            } else {
                newThread.set(Thread.currentThread())
                newServer
            }
        }
        try {
            transport.start {}
            assertTrue(oldEntered.await(5, TimeUnit.SECONDS))
            transport.close()
            transport.start {}
            Socket("127.0.0.1", newServer.localPort).use {
                assertTrue(attached.await(5, TimeUnit.SECONDS))
                releaseOld.countDown()
                oldThread.get().join(2_000)
                assertTrue(oldServer.isClosed)
                assertTrue(!oldThread.get().isAlive)
                assertTrue(!newServer.isClosed)
                transport.close()
                newThread.get().join(2_000)
                assertTrue(newServer.isClosed)
                assertTrue(!newThread.get().isAlive)
            }
        } finally {
            releaseOld.countDown()
            transport.close()
            oldServer.close()
            newServer.close()
            hub.closeAll()
        }
    }

    @Test fun wifiPeerStillAttachesWhenSendBufferTuningFails() = wifiPeerAttaches(tuningFails = true)

    @Test fun wifiPeerUsesTunedSendBuffer() = wifiPeerAttaches(tuningFails = false)

    private fun wifiPeerAttaches(tuningFails: Boolean) {
        val releaseReader = CountDownLatch(1)
        val input = object : java.io.InputStream() {
            override fun read(): Int {
                check(releaseReader.await(5, TimeUnit.SECONDS))
                return -1
            }
        }
        var requestedBuffer = 0
        val peer = object : Socket() {
            override fun getInetAddress() = java.net.InetAddress.getByName("192.0.2.1")
            override fun setTcpNoDelay(enabled: Boolean) = Unit
            override fun setSendBufferSize(size: Int) {
                requestedBuffer = size
                if (tuningFails) throw java.net.SocketException("test peer rejects buffer tuning")
            }
            override fun getInputStream() = input
            override fun getOutputStream() = java.io.ByteArrayOutputStream()
        }
        val closed = CountDownLatch(1)
        val server = object : ServerSocket() {
            private var accepted = false
            override fun accept(): Socket {
                if (!accepted) { accepted = true; return peer }
                check(closed.await(5, TimeUnit.SECONDS))
                throw java.net.SocketException("closed")
            }
            override fun close() { closed.countDown(); super.close() }
        }
        val hub = TransportHub()
        val attached = CountDownLatch(1)
        val listener = AtomicReference<Thread>()
        hub.onPeerAttached = { attached.countDown() }
        val transport = AdbSocketTransport(hub, 0) {
            listener.set(Thread.currentThread())
            server
        }
        try {
            assertEquals("adb-tcp", transport.name)
            transport.start {}
            assertTrue(attached.await(5, TimeUnit.SECONDS))
            assertEquals(TransportHub.wifiSendBufferBytes, requestedBuffer)
            assertEquals(1, hub.peerCount())
        } finally {
            transport.close()
            releaseReader.countDown()
            listener.get()?.join(2_000)
            hub.closeAll()
        }
    }

}
