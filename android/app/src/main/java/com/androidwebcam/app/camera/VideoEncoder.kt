package com.androidwebcam.app.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface

/**
 * Hardware encoder (AVC or HEVC) fed directly from Camera2 via an input
 * Surface. Prefer the [StreamProfile] constructor for quality-first
 * streaming; the legacy (width/height/fps/bitrate) form keeps the old
 * 6 Mbps CBR AVC behavior for compatibility.
 */
class VideoEncoder private constructor(
    val width: Int,
    val height: Int,
    val fps: Int,
    val profile: StreamProfile,
    private val onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
    private val onConfigSets: ((paramSets: List<ByteArray>) -> Unit)?,
    private val onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
) {
    private var codec: MediaCodec? = null
    val inputSurface: Surface

    init {
        val format = MediaFormat.createVideoFormat(profile.mime, profile.width, profile.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, profile.bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, profile.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, profile.iFrameIntervalSec)
            setInteger(MediaFormat.KEY_BITRATE_MODE, profile.bitrateMode)
            runCatching { setInteger("max-bframes", 0) } // low latency; ignored where unsupported
            runCatching { setInteger(MediaFormat.KEY_LATENCY, 0) }
        }
        codec = MediaCodec.createEncoderByType(profile.mime).also { prepared ->
            prepared.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, i: Int) = Unit

                override fun onOutputBufferAvailable(c: MediaCodec, i: Int, info: MediaCodec.BufferInfo) {
                    val buffer = c.getOutputBuffer(i) ?: return
                    buffer.position(info.offset); buffer.limit(info.offset + info.size)
                    val data = ByteArray(info.size).also { buffer.get(it) }
                    c.releaseOutputBuffer(i, false)
                    if (data.isEmpty()) return
                    // Some encoders (incl. this HEVC path) deliver VPS/SPS/PPS
                    // as a CODEC_CONFIG buffer instead of csd entries: consume
                    // it for CONFIG, never forward it as a video frame.
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        emitParamSets(listOf(data))
                        return
                    }
                    val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    onFrame(data, isKey, info.presentationTimeUs)
                }

                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) = Unit
                override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {
                    // AVC reports csd-0/1 (sps/pps); HEVC adds csd-2. Entries
                    // may each pack several NALs, so split before ordering.
                    val raw = (0..2).mapNotNull { n ->
                        f.getByteBuffer("csd-$n")?.let { bb ->
                            ByteArray(bb.remaining()).also { bb.get(it) }
                        }
                    }
                    if (raw.isNotEmpty()) emitParamSets(raw)
                }
            })
            prepared.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = prepared.createInputSurface()
        }
    }

    /** Quality-first constructor: HEVC/VBR capable, reports all csd sets. */
    constructor(
        profile: StreamProfile,
        onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
        onConfigSets: ((paramSets: List<ByteArray>) -> Unit)?,
        onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
    ) : this(profile.width, profile.height, profile.fps, profile,
        onConfig, onConfigSets, onFrame)

    private fun emitParamSets(raw: List<ByteArray>) {
        val nals = raw.flatMap { CodecConfig.splitAnnexB(it) }
        val ordered = CodecConfig.orderParamSets(profile.codec, nals) ?: return
        onConfig(ordered[ordered.size - 2], ordered[ordered.size - 1])
        onConfigSets?.invoke(ordered)
    }

    constructor(
        width: Int,
        height: Int,
        fps: Int = 30,
        bitrate: Int = 6_000_000,
        onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
        onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
    ) : this(
        width, height, fps,
        StreamProfile(
            codec = QualitySelector.AVC, width = width, height = height, fps = fps,
            bitrateBps = bitrate,
            bitrateMode = MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
            iFrameIntervalSec = 1,
        ),
        onConfig, null, onFrame,
    )

    fun start() { codec?.start() }

    fun requestKeyframe() {
        runCatching {
            codec?.setParameters(android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        }
    }

    fun stop() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        runCatching { inputSurface.release() }
    }
}
