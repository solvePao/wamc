package com.androidwebcam.app.camera

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * Quality-first streaming profiles. Bitrate ceilings come from the on-device
 * probe (SM-E236B: Qualcomm AVC/HEVC HW encoders, 1–100 Mbps, 1080p60+,
 * 4K30 perf point, VBR + CBR; CQ on the HEVC path).
 */
enum class StreamQuality(val key: String) {
    BEST("best"),
    HIGH("high"),
    BALANCED("balanced");

    companion object {
        fun parse(raw: String?): StreamQuality =
            entries.firstOrNull { it.key == raw?.lowercase() } ?: BEST
    }
}

data class StreamProfile(
    val codec: Int,
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrateBps: Int,
    val bitrateMode: Int,
    val iFrameIntervalSec: Int,
) {
    val mime: String get() = if (codec == CODECS_HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC
        else MediaFormat.MIMETYPE_VIDEO_AVC
}

private const val CODECS_HEVC = 1

/** Pure codec/quality picking so unit tests cover negotiation without hardware. */
object QualitySelector {
    const val AVC = 0
    const val HEVC = 1

    /** Defaults: BEST leans on VBR near transparency; HIGH doubles the old 6M clamp. */
    fun profileFor(
        quality: StreamQuality,
        codec: Int,
        wantW: Int,
        wantH: Int,
        fps: Int,
        bitrateOverrideBps: Int? = null,
        gopOverrideSec: Int? = null,
    ): StreamProfile {
        val base = when (quality) {
            StreamQuality.BEST -> Triple(
                if (codec == HEVC) 30_000_000 else 25_000_000,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR, 2)
            StreamQuality.HIGH -> Triple(
                12_000_000, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR, 2)
            StreamQuality.BALANCED -> Triple(
                8_000_000, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR, 2)
        }
        return StreamProfile(
            codec = codec,
            width = wantW, height = wantH, fps = fps,
            bitrateBps = bitrateOverrideBps?.takeIf { it > 0 } ?: base.first,
            bitrateMode = base.second,
            iFrameIntervalSec = gopOverrideSec?.takeIf { it in 1..10 } ?: base.third,
        )
    }

    /**
     * Picks the codec id. Unknown/legacy peers (null) stay on AVC so old Mac
     * builds keep decoding; explicit requests win when the phone supports them.
     */
    fun pickCodec(requested: String?, phoneCodecs: List<Int>, peerCodecs: List<Int>?): Int {
        val want = requested?.lowercase()
        if (want == "hevc" || want == "h265") return if (phoneCodecs.contains(HEVC)) HEVC else AVC
        if (want == "avc" || want == "h264") return AVC
        if (peerCodecs == null || (!peerCodecs.contains(AVC) && !peerCodecs.contains(HEVC))) {
            return AVC
        }
        return if (phoneCodecs.contains(HEVC) && peerCodecs.contains(HEVC)) HEVC else AVC
    }

    fun parsePeerCodecs(csv: String?): List<Int>? {
        if (csv.isNullOrBlank()) return null
        val out = csv.split(",").mapNotNull {
            when (it.trim().lowercase()) {
                "avc", "h264" -> AVC
                "hevc", "h265" -> HEVC
                else -> null
            }
        }
        return out.ifEmpty { null }
    }
}

/**
 * Decides where rotation happens. When the HAL supports rotate-and-crop, the
 * phone rotates in hardware and CONFIG reports 0 so the Mac just forwards
 * decoded frames. Otherwise rotation stays metadata and the Mac renders it.
 *
 * Mode ints mirror CaptureRequest.SCALER_ROTATE_AND_CROP_* (NONE=0, 90=1,
 * 180=2, 270=3) without loading framework classes in unit tests.
 */
object RotationPlanner {
    data class Plan(val halRotateMode: Int?, val configRotation: Int)

    fun plan(quarterTurns: Int, halSupportedModes: Set<Int>?): Plan {
        val turns = quarterTurns and 3
        if (turns == 0) return Plan(null, 0)
        val wantMode = turns // 1->90, 2->180, 3->270 matches the HAL enum values.
        return if (halSupportedModes?.contains(wantMode) == true) Plan(wantMode, 0)
        else Plan(null, turns)
    }
}

/** Hardware probe (needs a real device; never called from unit tests). */
object EncoderCaps {
    fun supportedCodecs(): List<Int> {
        return runCatching {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val out = mutableListOf<Int>()
            if (list.findEncoderForFormat(
                    MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720)
                ) != null) out += QualitySelector.AVC
            if (list.findEncoderForFormat(
                    MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, 1280, 720)
                ) != null) out += QualitySelector.HEVC
            out
        }.getOrDefault(listOf(QualitySelector.AVC))
    }

    fun csv(): String = supportedCodecs().joinToString(",") {
        if (it == QualitySelector.HEVC) "hevc" else "avc"
    }
}
