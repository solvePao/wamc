package com.androidwebcam.app

import android.media.MediaCodec
import android.media.MediaFormat
import com.androidwebcam.app.camera.QualitySelector
import com.androidwebcam.app.camera.StreamQuality
import com.androidwebcam.app.camera.VideoEncoderOutputHandler
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VideoEncoderOutputHandlerTest {
    private val profile = QualitySelector.profileFor(
        StreamQuality.BEST, QualitySelector.AVC, 640, 480, 30,
    )

    @Test fun outputFramesAndCodecConfigAreDispatchedSeparately() {
        var frame: Triple<ByteArray, Boolean, Long>? = null
        var config: Pair<ByteArray, ByteArray>? = null
        var sets: List<ByteArray>? = null
        val handler = VideoEncoderOutputHandler(
            profile,
            { sps, pps -> config = sps to pps },
            { sets = it },
            { data, key, pts -> frame = Triple(data, key, pts) },
        )

        handler.onOutput(byteArrayOf(), 0, 3L)
        assertEquals(null, frame)
        val data = byteArrayOf(7, 8)
        handler.onOutput(data, MediaCodec.BUFFER_FLAG_KEY_FRAME, 99L)
        assertArrayEquals(data, frame!!.first)
        assertTrue(frame!!.second)
        assertEquals(99L, frame!!.third)

        val codecData = annexB(0x67, 0x64) + annexB(0x68, 0xee.toByte())
        handler.onOutput(codecData, MediaCodec.BUFFER_FLAG_CODEC_CONFIG, 100L)
        assertArrayEquals(byteArrayOf(0x67, 0x64), config!!.first)
        assertArrayEquals(byteArrayOf(0x68, 0xee.toByte()), config!!.second)
        assertEquals(2, sets!!.size)
        assertArrayEquals(data, frame!!.first)
    }

    @Test fun formatChangeReadsCsdAndIgnoresIncompleteSets() {
        var config: Pair<ByteArray, ByteArray>? = null
        var frameCount = 0
        val handler = VideoEncoderOutputHandler(
            profile, { sps, pps -> config = sps to pps }, null, { _, _, _ -> frameCount++ },
        )
        handler.onOutputFormatChanged(MediaFormat())
        assertFalse(config != null)

        val format = MediaFormat().apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(annexB(0x67, 0x42)))
            setByteBuffer("csd-1", ByteBuffer.wrap(annexB(0x68, 0x01)))
        }
        handler.onOutputFormatChanged(format)
        assertArrayEquals(byteArrayOf(0x67, 0x42), config!!.first)
        assertArrayEquals(byteArrayOf(0x68, 0x01), config!!.second)
        handler.onOutput(byteArrayOf(1), 0, 0)
        assertEquals(1, frameCount)
    }

    private fun annexB(first: Int, second: Byte) = byteArrayOf(0, 0, 0, 1, first.toByte(), second)
}
