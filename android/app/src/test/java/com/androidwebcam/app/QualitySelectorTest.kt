package com.androidwebcam.app

import android.media.MediaCodecInfo
import com.androidwebcam.app.camera.CodecConfig
import com.androidwebcam.app.camera.QualitySelector
import com.androidwebcam.app.camera.RotationPlanner
import com.androidwebcam.app.camera.StreamQuality
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QualitySelectorTest {

    @Test fun autoPrefersHevcWhenBothEndsSupportIt() {
        assertEquals(QualitySelector.HEVC,
            QualitySelector.pickCodec("auto", listOf(0, 1), listOf(0, 1)))
    }

    @Test fun unknownPeerStaysAvcForLegacyMacBuilds() {
        assertEquals(QualitySelector.AVC,
            QualitySelector.pickCodec("auto", listOf(0, 1), null))
        assertEquals(QualitySelector.AVC,
            QualitySelector.pickCodec(null, listOf(0, 1), emptyList()))
    }

    @Test fun explicitHevcFallsBackToAvcWithoutPhoneSupport() {
        assertEquals(QualitySelector.AVC,
            QualitySelector.pickCodec("hevc", listOf(0), listOf(0, 1)))
        assertEquals(QualitySelector.AVC,
            QualitySelector.pickCodec("avc", listOf(0, 1), listOf(0, 1)))
    }

    @Test fun peerCodecsParseIgnoresUnknownTokens() {
        assertEquals(listOf(0, 1), QualitySelector.parsePeerCodecs("avc,hevc"))
        assertNull(QualitySelector.parsePeerCodecs(null))
        assertNull(QualitySelector.parsePeerCodecs("vp9"))
    }

    @Test fun bestProfileUsesHighVbrCeilingNotLegacy6M() {
        val hevc = QualitySelector.profileFor(StreamQuality.BEST, 1, 1920, 1080, 30)
        assertEquals(30_000_000, hevc.bitrateBps)
        assertEquals(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR, hevc.bitrateMode)
        val avc = QualitySelector.profileFor(StreamQuality.BEST, 0, 1920, 1080, 30)
        assertEquals(25_000_000, avc.bitrateBps)
        val high = QualitySelector.profileFor(StreamQuality.HIGH, 0, 1920, 1080, 30)
        assertEquals(12_000_000, high.bitrateBps)
    }

    @Test fun wifiLowLatencyScalesBitrateTo75PercentAndGopTo1() {
        val bestHevc = QualitySelector.profileFor(
            StreamQuality.BEST, 1, 1920, 1080, 30, lowLatency = true)
        assertEquals(22_500_000, bestHevc.bitrateBps)
        assertEquals(1, bestHevc.iFrameIntervalSec)
        assertEquals(1920, bestHevc.width); assertEquals(1080, bestHevc.height)
        assertEquals(30, bestHevc.fps)
        val bestAvc = QualitySelector.profileFor(
            StreamQuality.BEST, 0, 1920, 1080, 30, lowLatency = true)
        assertEquals(18_750_000, bestAvc.bitrateBps)
        val high = QualitySelector.profileFor(
            StreamQuality.HIGH, 1, 1920, 1080, 30, lowLatency = true)
        assertEquals(9_000_000, high.bitrateBps)
        val balanced = QualitySelector.profileFor(
            StreamQuality.BALANCED, 0, 1280, 720, 30, lowLatency = true)
        assertEquals(6_000_000, balanced.bitrateBps)
    }

    @Test fun usbProfileUnchangedWhenNotLowLatency() {
        val p = QualitySelector.profileFor(StreamQuality.BEST, 1, 1920, 1080, 30)
        assertEquals(30_000_000, p.bitrateBps)
        assertEquals(2, p.iFrameIntervalSec)
    }

    @Test fun overridesWinOverWifiScaling() {
        val p = QualitySelector.profileFor(
            StreamQuality.BEST, 1, 1920, 1080, 30,
            bitrateOverrideBps = 10_000_000, gopOverrideSec = 3, lowLatency = true)
        assertEquals(10_000_000, p.bitrateBps)
        assertEquals(3, p.iFrameIntervalSec)
    }

    @Test fun overridesAreHonoredWithinSanityBounds() {
        val p = QualitySelector.profileFor(
            StreamQuality.BEST, 0, 1920, 1080, 30,
            bitrateOverrideBps = 40_000_000, gopOverrideSec = 5)
        assertEquals(40_000_000, p.bitrateBps)
        assertEquals(5, p.iFrameIntervalSec)
        val clamped = QualitySelector.profileFor(
            StreamQuality.BEST, 0, 1920, 1080, 30, gopOverrideSec = 99)
        assertEquals(2, clamped.iFrameIntervalSec)
    }
}

class CodecConfigTest {

    private fun nal(vararg bytes: Byte): ByteArray = byteArrayOf(0, 0, 0, 1, *bytes)

    @Test fun unrecognizedZeroPrefixRemainsPayload() {
        val payload = byteArrayOf(0, 0, 0, 0, 0x67)
        assertArrayEquals(payload, CodecConfig.splitAnnexB(payload).single())
    }

    @Test fun splitsMixedStartCodes() {
        val blob = nal(0x67, 0x01) + byteArrayOf(0, 0, 1, 0x68, 0x02)
        val nals = CodecConfig.splitAnnexB(blob)
        assertEquals(2, nals.size)
        assertArrayEquals(byteArrayOf(0x67, 0x01), nals[0])
        assertArrayEquals(byteArrayOf(0x68, 0x02), nals[1])
    }

    @Test fun ordersAvcSpsPps() {
        val sps = byteArrayOf(0x67, 0x64); val pps = byteArrayOf(0x68, 0xEE.toByte())
        val ordered = CodecConfig.orderParamSets(0, listOf(pps, sps))
        assertEquals(2, ordered!!.size)
        assertArrayEquals(sps, ordered[0]); assertArrayEquals(pps, ordered[1])
    }

    @Test fun ordersHevcVpsSpsPps() {
        // HEVC nal types 32/33/34 have first bytes 0x40/0x42/0x44.
        val vps = byteArrayOf(0x40, 0x01); val sps = byteArrayOf(0x42, 0x01); val pps = byteArrayOf(0x44, 0x01)
        val blob = nal(0x44, 0x01) + nal(0x40, 0x01) + nal(0x42, 0x01)
        val ordered = CodecConfig.orderParamSets(1, CodecConfig.splitAnnexB(blob))
        assertEquals(3, ordered!!.size)
        assertArrayEquals(vps, ordered[0])
        assertArrayEquals(sps, ordered[1])
        assertArrayEquals(pps, ordered[2])
    }

    @Test fun incompleteSetsReturnNull() {
        assertNull(CodecConfig.orderParamSets(0, listOf(byteArrayOf(0x67))))
        assertNull(CodecConfig.orderParamSets(1, listOf(byteArrayOf(0x40), byteArrayOf(0x42))))
        assertNull(CodecConfig.orderParamSets(0, emptyList()))
    }
}

class RotationPlannerTest {

    @Test fun zeroTurnsNeedNoHalWork() {
        assertEquals(RotationPlanner.Plan(null, 0), RotationPlanner.plan(0, setOf(1, 2, 3)))
    }

    @Test fun halRotateClearsMacRotation() {
        assertEquals(RotationPlanner.Plan(1, 0), RotationPlanner.plan(1, setOf(1, 2, 3)))
        assertEquals(RotationPlanner.Plan(3, 0), RotationPlanner.plan(3, setOf(1, 2, 3)))
    }

    @Test fun unsupportedHalFallsBackToMetadataRotation() {
        assertEquals(RotationPlanner.Plan(null, 1), RotationPlanner.plan(1, null))
        assertEquals(RotationPlanner.Plan(null, 2), RotationPlanner.plan(2, setOf(1)))
    }
}
