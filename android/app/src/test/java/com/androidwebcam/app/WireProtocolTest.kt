package com.androidwebcam.app

import com.androidwebcam.app.protocol.WireProtocol
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.EOFException
import java.nio.ByteBuffer
import java.nio.ByteOrder

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

    @Test fun readerResynchronizesAfterGarbageAndOverlappingMagicPrefix() {
        val frame = WireProtocol.encode(3, 0, 9L, byteArrayOf(1, 2))
        val stream = ByteArrayInputStream(byteArrayOf(0x41, 0x41, 0x57, 0x43) + frame)
        assertEquals(WireProtocol.Frame(3, 0, 9L, byteArrayOf(1, 2)), WireProtocol.readFrame(stream))
    }

    @Test fun readerRejectsEofAndMalformedPayloadLengths() {
        assertThrows<EOFException> { WireProtocol.readFrame(ByteArrayInputStream(byteArrayOf())) }
        val truncatedHeader = WireProtocol.MAGIC + byteArrayOf(1, 0, 0)
        assertThrows<EOFException> { WireProtocol.readFrame(ByteArrayInputStream(truncatedHeader)) }

        val invalidLength = ByteBuffer.allocate(WireProtocol.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
            .put(WireProtocol.MAGIC).put(1).put(0).putShort(0).putLong(0).putInt(-1).array()
        assertThrows<IllegalArgumentException> {
            WireProtocol.readFrame(ByteArrayInputStream(invalidLength))
        }
        val midPayload = WireProtocol.encode(1, 0, 0, byteArrayOf(1, 2)).dropLast(1).toByteArray()
        assertThrows<EOFException> {
            WireProtocol.readFrame(ByteArrayInputStream(midPayload))
        }
    }

    @Test fun configV2RejectsUnknownCodecAndInvalidSetCount() {
        assertThrows<IllegalArgumentException> {
            WireProtocol.encodeConfigV2(3, listOf(byteArrayOf(1)), 1, 1, 1)
        }
        assertThrows<IllegalArgumentException> {
            WireProtocol.encodeConfigV2(WireProtocol.CODEC_AVC, emptyList(), 1, 1, 1)
        }
        assertThrows<IllegalArgumentException> { WireProtocol.decodeConfigV2(byteArrayOf(3, 1)) }
        assertThrows<IllegalArgumentException> { WireProtocol.decodeConfigV2(byteArrayOf(0, 0)) }
    }

    @Test fun controlDecoderIgnoresMalformedFieldsAndKeepsLastDuplicate() {
        assertEquals(mapOf("cmd" to "stop", "key" to "value"),
            WireProtocol.decodeControl("ignored;cmd=start;key=value;cmd=stop".toByteArray()))
    }

    @Test fun frameEqualityAndHashIncludePayloadContents() {
        val first = WireProtocol.Frame(1, 1, 10, byteArrayOf(1, 2))
        val equal = WireProtocol.Frame(1, 1, 10, byteArrayOf(1, 2))
        val different = WireProtocol.Frame(1, 1, 10, byteArrayOf(1, 3))
        assertEquals(first, equal)
        assertEquals(first.hashCode(), equal.hashCode())
        assertEquals(false, first == different)
    }

    private inline fun <reified T : Throwable> assertThrows(noinline block: () -> Unit) {
        try {
            block()
            throw AssertionError("Expected ${T::class.java.simpleName}")
        } catch (error: Throwable) {
            if (error !is T) throw error
        }
    }
}
