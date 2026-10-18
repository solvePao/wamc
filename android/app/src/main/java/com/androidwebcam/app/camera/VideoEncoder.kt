package com.androidwebcam.app.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import com.androidwebcam.app.util.AppLog

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
    private val lowLatency: Boolean,
    private val onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
    private val onConfigSets: ((paramSets: List<ByteArray>) -> Unit)?,
    private val onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
) : StreamingEncoder {
    private var codec: MediaCodec? = null
    override val inputSurface: Surface
    private val outputHandler = VideoEncoderOutputHandler(profile, onConfig, onConfigSets, onFrame)
    private lateinit var lifecycle: EncoderLifecycle

    init {
        val format = MediaFormat.createVideoFormat(profile.mime, profile.width, profile.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, profile.bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, profile.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, profile.iFrameIntervalSec)
            setInteger(MediaFormat.KEY_BITRATE_MODE, profile.bitrateMode)
            runCatching { setInteger("max-bframes", 0) } // low latency; ignored where unsupported
            runCatching { setInteger(MediaFormat.KEY_LATENCY, 0) }
            if (lowLatency) {
                // Wi-Fi path: ask the encoder for realtime priority and an
                // operating rate at the target fps. Hints only — the output
                // format log in onOutputFormatChanged shows what stuck.
                runCatching { setInteger(MediaFormat.KEY_PRIORITY, 0) }
                runCatching { setInteger(MediaFormat.KEY_OPERATING_RATE, profile.fps) }
            }
        }
        codec = MediaCodec.createEncoderByType(profile.mime).also { prepared ->
            prepared.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, i: Int) = Unit

                override fun onOutputBufferAvailable(c: MediaCodec, i: Int, info: MediaCodec.BufferInfo) {
                    val buffer = c.getOutputBuffer(i) ?: return
                    buffer.position(info.offset); buffer.limit(info.offset + info.size)
                    val data = ByteArray(info.size).also { buffer.get(it) }
                    c.releaseOutputBuffer(i, false)
                    outputHandler.onOutput(data, info.flags, info.presentationTimeUs)
                }

                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                    AppLog.error("VideoEncoder", "encoder callback failed (${e.errorCode})", e)
                }
                override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {
                    if (lowLatency) {
                        AppLog.debug("VideoEncoder", "Wi-Fi output format: $f")
                    }
                    outputHandler.onOutputFormatChanged(f)
                }
            })
            prepared.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = prepared.createInputSurface()
        }
        lifecycle = EncoderLifecycle(object : EncoderRuntime {
            override fun start() = checkNotNull(codec) { "encoder is not initialized" }.start()
            override fun requestKeyframe() {
                codec?.setParameters(android.os.Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            }
            override fun stop() { codec?.stop() }
            override fun release() { codec?.release(); codec = null }
            override fun releaseInputSurface() { inputSurface.release() }
        }, profile)
    }

    /** Quality-first constructor: HEVC/VBR capable, reports all csd sets. */
    constructor(
        profile: StreamProfile,
        onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
        onConfigSets: ((paramSets: List<ByteArray>) -> Unit)?,
        onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
        lowLatency: Boolean = false,
    ) : this(profile.width, profile.height, profile.fps, profile, lowLatency,
        onConfig, onConfigSets, onFrame)

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
        false, onConfig, null, onFrame,
    )

    override fun start() {
        lifecycle.start()
    }

    override fun requestKeyframe() = lifecycle.requestKeyframe()

    override fun stop() = lifecycle.stop()
}

/** Processes codec output independently of the hardware callback adapter. */
internal class VideoEncoderOutputHandler(
    private val profile: StreamProfile,
    private val onConfig: (sps: ByteArray, pps: ByteArray) -> Unit,
    private val onConfigSets: ((paramSets: List<ByteArray>) -> Unit)?,
    private val onFrame: (data: ByteArray, isKeyframe: Boolean, ptsUs: Long) -> Unit,
) {
    fun onOutput(data: ByteArray, flags: Int, presentationTimeUs: Long) {
        if (data.isEmpty()) return
        if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            emitParamSets(listOf(data))
            return
        }
        onFrame(data, flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0, presentationTimeUs)
    }

    fun onOutputFormatChanged(format: MediaFormat) {
        val raw = (0..2).mapNotNull { index ->
            format.getByteBuffer("csd-$index")?.let { buffer ->
                ByteArray(buffer.remaining()).also { buffer.get(it) }
            }
        }
        if (raw.isNotEmpty()) emitParamSets(raw)
    }

    private fun emitParamSets(raw: List<ByteArray>) {
        val nals = raw.flatMap { CodecConfig.splitAnnexB(it) }
        val ordered = CodecConfig.orderParamSets(profile.codec, nals) ?: return
        onConfig(ordered[ordered.size - 2], ordered[ordered.size - 1])
        onConfigSets?.invoke(ordered)
    }
}
