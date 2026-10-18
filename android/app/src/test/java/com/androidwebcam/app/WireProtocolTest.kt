package com.androidwebcam.app

import com.androidwebcam.app.protocol.WireProtocol
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream

class WireProtocolTest {

    @Test fun goldenVectorMatchesSpec() {
        val payload = byteArrayOf(0, 0, 0, 1, 0x65, 0x88.toByte())
        val bytes = WireProtocol.encode(1, 1, 1000L, payload)
        val expected = "415743310101000000000000000003e800000006000000016588"
        assertEquals(expected, bytes.joinToString("") { "%02x".format(it) })
    }

    @Test fun roundTripThroughStream() {
        val payload = byteArrayOf(0, 0, 0, 1, 0x67, 0x42)
        val bytes = WireProtocol.encode(1, 1, 42L, payload)
        val frame = WireProtocol.readFrame(ByteArrayInputStream(bytes))
        assertEquals(1, frame.type)
        assertEquals(42L, frame.ptsUs)
        assertArrayEquals(payload, frame.payload)
    }

    @Test fun configRoundTrip() {
        val sps = byteArrayOf(0x67, 0x64, 0x00); val pps = byteArrayOf(0x68, 0xEE.toByte())
        val cfg = WireProtocol.decodeConfig(WireProtocol.encodeConfig(sps, pps, 1920, 1080, 30, rotation = 1))
        assertArrayEquals(sps, cfg.sps); assertArrayEquals(pps, cfg.pps)
        assertEquals(1920, cfg.width); assertEquals(1080, cfg.height)
        assertEquals(30, cfg.fps)
        assertEquals(1, cfg.rotation)
    }

    @Test fun controlRoundTrip() {
        val fields = mapOf("cmd" to "start", "facing" to "back", "width" to "1920")
        assertEquals(fields, WireProtocol.decodeControl(WireProtocol.encodeControl(fields)))
    }

    @Test fun configV2AvcRoundTrip() {
        val sps = byteArrayOf(0x67, 0x64, 0x00); val pps = byteArrayOf(0x68, 0xEE.toByte())
        val cfg = WireProtocol.decodeConfigV2(
            WireProtocol.encodeConfigV2(0, listOf(sps, pps), 1920, 1080, 30, rotation = 0))
        assertEquals(0, cfg.codec)
        assertEquals(2, cfg.paramSets.size)
        assertArrayEquals(sps, cfg.paramSets[0]); assertArrayEquals(pps, cfg.paramSets[1])
        assertEquals(1920, cfg.width); assertEquals(1080, cfg.height)
        assertEquals(30, cfg.fps); assertEquals(0, cfg.rotation)
    }

    @Test fun configV2HevcRoundTripKeepsVpsSpsPpsOrder() {
        val vps = byteArrayOf(0x40, 0x01); val sps = byteArrayOf(0x42, 0x01); val pps = byteArrayOf(0x44, 0x01)
        val cfg = WireProtocol.decodeConfigV2(
            WireProtocol.encodeConfigV2(1, listOf(vps, sps, pps), 3840, 2160, 30, rotation = 0))
        assertEquals(1, cfg.codec)
        assertEquals(3, cfg.paramSets.size)
        assertArrayEquals(vps, cfg.paramSets[0])
        assertArrayEquals(sps, cfg.paramSets[1])
        assertArrayEquals(pps, cfg.paramSets[2])
        assertEquals(3840, cfg.width); assertEquals(2160, cfg.height)
    }

    @Test fun legacyConfigStillDecodesAfterV2Added() {
        val sps = byteArrayOf(0x67, 0x64, 0x00); val pps = byteArrayOf(0x68, 0xEE.toByte())
        val cfg = WireProtocol.decodeConfig(WireProtocol.encodeConfig(sps, pps, 1280, 720, 30, rotation = 2))
        assertEquals(1280, cfg.width); assertEquals(720, cfg.height); assertEquals(2, cfg.rotation)
    }

    @Test fun controlCarriesNegotiationKeys() {
        val fields = mapOf("cmd" to "start", "codec" to "auto", "quality" to "best",
            "bitrate" to "30000000", "gop" to "2")
        assertEquals(fields, WireProtocol.decodeControl(WireProtocol.encodeControl(fields)))
    }
}
