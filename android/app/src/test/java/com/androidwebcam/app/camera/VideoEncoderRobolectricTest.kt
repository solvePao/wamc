package com.androidwebcam.app.camera

import android.media.MediaFormat
import android.media.MediaCodec
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowMediaCodec

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], shadows = [VideoEncoderRobolectricTest.SurfaceCodecShadow::class])
class VideoEncoderRobolectricTest {
    @After fun clearCodecs() {
        ShadowMediaCodec.clearCodecs()
        org.robolectric.shadows.ShadowMediaCodecList.reset()
    }

    @Test fun createsStartsRequestsKeyframeAndReleasesAvcEncoder() {
        ShadowMediaCodec.addEncoder("video/avc", codecConfig())
        val profile = QualitySelector.profileFor(StreamQuality.BEST, QualitySelector.AVC, 640, 480, 30)
        val encoder = VideoEncoder(profile, { _, _ -> }, null, { _, _, _ -> }, lowLatency = true)

        assertEquals(profile, encoder.profile)
        assertEquals(640, encoder.width)
        assertEquals(480, encoder.height)
        encoder.start()
        encoder.requestKeyframe()
        encoder.stop()
    }

    @Test fun appliesLowLatencyFormatOptionsAndSupportsLegacyConstructor() {
        ShadowMediaCodec.addEncoder("video/avc", codecConfig())
        val encoder = VideoEncoder(640, 480, 24, 2_000_000, { _, _ -> }, { _, _, _ -> })
        assertEquals(24, encoder.fps)
        encoder.start()
        encoder.stop()
    }

    @Test fun codecCallbacksDispatchFramesAndFormatConfiguration() {
        ShadowMediaCodec.addEncoder("video/avc", codecConfig())
        val profile = QualitySelector.profileFor(StreamQuality.BEST, QualitySelector.AVC, 640, 480, 30)
        var frameCount = 0
        var configCount = 0
        val encoder = VideoEncoder(profile, { _, _ -> configCount++ }, { configCount++ },
            { _, _, _ -> frameCount++ }, lowLatency = true)
        val codec = VideoEncoder::class.java.getDeclaredField("codec").apply { isAccessible = true }
            .get(encoder) as MediaCodec
        encoder.start()
        val shadow = org.robolectric.shadow.api.Shadow.extract<ShadowMediaCodec>(codec)
        val callback = ShadowMediaCodec::class.java.getDeclaredField("callback").apply {
            isAccessible = true
        }.get(shadow) as MediaCodec.Callback
        callback.onInputBufferAvailable(codec, 0)
        val error = MediaCodec.CodecException::class.java.getDeclaredConstructor(
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java,
        ).apply { isAccessible = true }.newInstance(1100, 0, "simulated encoder error")
        callback.onError(codec, error)
        org.junit.Assert.assertTrue(org.robolectric.shadows.ShadowLog.getLogsForTag("AWC")
            .any { it.msg.contains("encoder callback failed") })
        val info = MediaCodec.BufferInfo().apply {
            set(0, 4, 11L, MediaCodec.BUFFER_FLAG_KEY_FRAME)
        }
        callback.onOutputBufferAvailable(codec, 0, info)
        assertEquals(1, frameCount)
        val format = MediaFormat().apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1, 0x67, 0x42)))
            setByteBuffer("csd-1", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1, 0x68, 0x01)))
        }
        callback.onOutputFormatChanged(codec, format)
        assertEquals(2, configCount)
        encoder.stop()
    }

    @Test fun defaultProfilesAndLegacyDefaultsCreateUsableSurface() {
        ShadowMediaCodec.addEncoder("video/avc", codecConfig())
        val profile = QualitySelector.profileFor(StreamQuality.BEST, QualitySelector.AVC, 640, 480, 30)
        val modern = VideoEncoder(profile, { _, _ -> }, null, { _, _, _ -> })
        assertEquals(profile, modern.profile)
        modern.start()
        modern.stop()
        org.junit.Assert.assertFalse(modern.inputSurface.isValid)
        val legacy = VideoEncoder(640, 480, onConfig = { _, _ -> }, onFrame = { _, _, _ -> })
        assertEquals(30, legacy.fps)
        assertEquals(6_000_000, legacy.profile.bitrateBps)
        legacy.start()
        legacy.stop()
    }

    @Test fun encoderCapabilitiesAdvertiseAvcAndHevcWhenHardwareSupportsBoth() {
        for (mime in listOf("video/avc", "video/hevc")) {
            val capabilities = org.robolectric.shadows.MediaCodecInfoBuilder.CodecCapabilitiesBuilder.newBuilder()
                .setMediaFormat(MediaFormat.createVideoFormat(mime, 1280, 720))
                .setIsEncoder(true)
                .setProfileLevels(arrayOf(android.media.MediaCodecInfo.CodecProfileLevel().apply {
                    profile = if (mime == "video/avc") android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                        else android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
                    level = if (mime == "video/avc") android.media.MediaCodecInfo.CodecProfileLevel.AVCLevel4
                        else android.media.MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel4
                }))
                .setColorFormats(intArrayOf(android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface))
                .build()
            org.robolectric.shadows.ShadowMediaCodecList.addCodec(
                org.robolectric.shadows.MediaCodecInfoBuilder.newBuilder()
                    .setName("test-encoder-$mime").setIsEncoder(true).setCapabilities(capabilities).build())
        }
        assertEquals(listOf(QualitySelector.AVC, QualitySelector.HEVC), EncoderCaps.supportedCodecs())
        assertEquals("avc,hevc", EncoderCaps.csv())
    }

    @org.robolectric.annotation.Implements(MediaCodec::class)
    class SurfaceCodecShadow : ShadowMediaCodec() {
        @org.robolectric.annotation.Implementation
        protected fun createInputSurface() = android.view.Surface(android.graphics.SurfaceTexture(0))
    }

    private fun codecConfig() = ShadowMediaCodec.CodecConfig(
        4,
        4,
        object : ShadowMediaCodec.CodecConfig.Codec {
            override fun process(input: java.nio.ByteBuffer, output: java.nio.ByteBuffer) = Unit
            override fun onConfigured(format: MediaFormat, surface: android.view.Surface?,
                crypto: android.media.MediaCrypto?, flags: Int) = Unit
        },
    )
}
