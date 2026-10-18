package com.androidwebcam.app.camera

/**
 * Pure helpers that turn raw codec-config bytes (csd buffers or
 * BUFFER_FLAG_CODEC_CONFIG frames) into ordered parameter sets:
 * AVC [sps, pps], HEVC [vps, sps, pps]. No Android APIs; unit tested.
 */
object CodecConfig {
    private fun startCodeLengthAt(data: ByteArray, i: Int): Int {
        if (i + 2 >= data.size) return 0
        if (data[i] != 0.toByte() || data[i + 1] != 0.toByte()) return 0
        if (data[i + 2] == 1.toByte()) return 3
        if (i + 3 < data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) return 4
        return 0
    }

    /** Splits Annex-B into raw NALs (start codes excluded). No codes → whole input. */
    fun splitAnnexB(data: ByteArray): List<ByteArray> {
        if (data.isEmpty()) return emptyList()
        val codeBegins = mutableListOf<Int>()
        val payloadBegins = mutableListOf<Int>()
        var i = 0
        while (i < data.size) {
            val len = startCodeLengthAt(data, i)
            if (len > 0) {
                codeBegins += i
                payloadBegins += i + len
                i += len
            } else {
                i++
            }
        }
        if (codeBegins.isEmpty()) return listOf(data)
        return payloadBegins.mapIndexed { idx, payload ->
            val end = if (idx + 1 < payloadBegins.size) codeBegins[idx + 1] else data.size
            data.copyOfRange(payload, end)
        }.filter { it.isNotEmpty() }
    }

    fun avcNalType(nal: ByteArray): Int = nal[0].toInt() and 0x1F

    fun hevcNalType(nal: ByteArray): Int = ((nal[0].toInt() and 0xFF) shr 1) and 0x3F

    /**
     * Orders raw NALs as [sps, pps] (AVC: types 7/8) or [vps, sps, pps]
     * (HEVC: types 32/33/34). Returns null when any set is missing.
     */
    fun orderParamSets(codec: Int, nals: List<ByteArray>): List<ByteArray>? {
        if (nals.any { it.isEmpty() }) return null
        return if (codec == QualitySelector.HEVC) {
            val vps = nals.firstOrNull { hevcNalType(it) == 32 } ?: return null
            val sps = nals.firstOrNull { hevcNalType(it) == 33 } ?: return null
            val pps = nals.firstOrNull { hevcNalType(it) == 34 } ?: return null
            listOf(vps, sps, pps)
        } else {
            val sps = nals.firstOrNull { avcNalType(it) == 7 } ?: return null
            val pps = nals.firstOrNull { avcNalType(it) == 8 } ?: return null
            listOf(sps, pps)
        }
    }
}
