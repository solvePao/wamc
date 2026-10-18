package com.androidwebcam.app.protocol

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** AWC1 framing. See shared/protocol/PROTOCOL.md. */
object WireProtocol {
    const val HEADER_SIZE = 20
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    val MAGIC = byteArrayOf(0x41, 0x57, 0x43, 0x31) // AWC1

    const val TYPE_VIDEO = 1
    const val TYPE_CONFIG = 2
    const val TYPE_CONTROL = 3
    const val TYPE_HELLO = 4
    /** Codec-negotiated config carrying 2 (AVC) or 3 (HEVC) parameter sets. */
    const val TYPE_CONFIG2 = 5
    const val FLAG_KEYFRAME = 1

    /** Codec ids used in CONFIG2 and HELLO/CONTROL negotiation. */
    const val CODEC_AVC = 0
    const val CODEC_HEVC = 1

    data class Frame(val type: Int, val flags: Int, val ptsUs: Long, val payload: ByteArray) {
        val isKeyframe get() = flags and FLAG_KEYFRAME != 0
        override fun equals(other: Any?): Boolean {
            if (other !is Frame) return false
            return type == other.type && flags == other.flags && ptsUs == other.ptsUs &&
                payload.contentEquals(other.payload)
        }
        override fun hashCode(): Int =
            31 * (31 * type + flags) + ptsUs.hashCode() * 31 + payload.contentHashCode()
    }

    fun encode(type: Int, flags: Int, ptsUs: Long, payload: ByteArray): ByteArray {
        require(payload.size <= MAX_PAYLOAD) { "payload too large" }
        val out = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        out.put(MAGIC).put(type.toByte()).put(flags.toByte()).putShort(0)
        out.putLong(ptsUs).putInt(payload.size).put(payload)
        return out.array()
    }

    fun writeFrame(out: OutputStream, frame: Frame) {
        out.write(encode(frame.type, frame.flags, frame.ptsUs, frame.payload))
        out.flush()
    }

    /** Blocking read of one frame; rescans to the next magic on garbage. */
    fun readFrame(input: InputStream): Frame {
        val header = ByteArray(HEADER_SIZE)
        var matched = 0
        while (matched < 4) {
            val b = input.read()
            if (b < 0) throw EOFException("stream closed")
            if (b.toByte() == MAGIC[matched]) matched++ else matched = if (b.toByte() == MAGIC[0]) 1 else 0
        }
        readFully(input, header, 4, HEADER_SIZE - 4)
        System.arraycopy(MAGIC, 0, header, 0, 4)
        val buf = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN)
        val type = buf.get(4).toInt() and 0xFF
        val flags = buf.get(5).toInt() and 0xFF
        val ptsUs = buf.getLong(8)
        val len = buf.getInt(16)
        require(len in 0..MAX_PAYLOAD) { "bad payload length $len" }
        val payload = ByteArray(len)
        readFully(input, payload, 0, len)
        return Frame(type, flags, ptsUs, payload)
    }

    private fun readFully(input: InputStream, dst: ByteArray, off: Int, len: Int) {
        var read = 0
        while (read < len) {
            val n = input.read(dst, off + read, len - read)
            if (n < 0) throw EOFException("stream closed mid-frame")
            read += n
        }
    }

    /** [rotation] is quarter-turns clockwise (0..3) for the receiver to apply. */
    fun encodeConfig(sps: ByteArray, pps: ByteArray, width: Int, height: Int, fps: Int, rotation: Int = 0): ByteArray {
        val out = ByteBuffer.allocate(2 + sps.size + 2 + pps.size + 6).order(ByteOrder.BIG_ENDIAN)
        out.putShort(sps.size.toShort()).put(sps)
        out.putShort(pps.size.toShort()).put(pps)
        out.putShort(width.toShort()).putShort(height.toShort())
        out.put(fps.toByte()).put((rotation and 3).toByte())
        return out.array()
    }

    data class Config(
        val sps: ByteArray, val pps: ByteArray, val width: Int, val height: Int,
        val fps: Int, val rotation: Int = 0,
    )

    fun decodeConfig(payload: ByteArray): Config {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val sps = ByteArray(buf.short.toInt() and 0xFFFF).also { buf.get(it) }
        val pps = ByteArray(buf.short.toInt() and 0xFFFF).also { buf.get(it) }
        return Config(sps, pps, buf.short.toInt() and 0xFFFF, buf.short.toInt() and 0xFFFF,
            buf.get().toInt() and 0xFF, buf.get().toInt() and 0x03)
    }

    /**
     * CONFIG2 layout: `codec u8 | count u8 | (len u16 + bytes)* | width u16 |
     * height u16 | fps u8 | rotation u8`. AVC sends sps,pps; HEVC sends
     * vps,sps,pps in that order. Legacy receivers skip it as an unknown type.
     */
    fun encodeConfigV2(
        codec: Int, paramSets: List<ByteArray>,
        width: Int, height: Int, fps: Int, rotation: Int = 0,
    ): ByteArray {
        require(codec == CODEC_AVC || codec == CODEC_HEVC) { "unknown codec $codec" }
        require(paramSets.size in 1..8) { "need 1..8 parameter sets" }
        val out = ByteBuffer.allocate(
            2 + paramSets.sumOf { 2 + it.size } + 6).order(ByteOrder.BIG_ENDIAN)
        out.put(codec.toByte()).put(paramSets.size.toByte())
        paramSets.forEach { out.putShort(it.size.toShort()).put(it) }
        out.putShort(width.toShort()).putShort(height.toShort())
        out.put(fps.toByte()).put((rotation and 3).toByte())
        return out.array()
    }

    data class ConfigV2(
        val codec: Int, val paramSets: List<ByteArray>, val width: Int, val height: Int,
        val fps: Int, val rotation: Int = 0,
    )

    fun decodeConfigV2(payload: ByteArray): ConfigV2 {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val codec = buf.get().toInt() and 0xFF
        require(codec == CODEC_AVC || codec == CODEC_HEVC) { "unknown codec $codec" }
        val count = buf.get().toInt() and 0xFF
        require(count in 1..8) { "bad parameter set count $count" }
        val sets = (0 until count).map {
            ByteArray(buf.short.toInt() and 0xFFFF).also { bytes -> buf.get(bytes) }
        }
        return ConfigV2(codec, sets, buf.short.toInt() and 0xFFFF, buf.short.toInt() and 0xFFFF,
            buf.get().toInt() and 0xFF, buf.get().toInt() and 0x03)
    }

    fun encodeControl(fields: Map<String, String>): ByteArray =
        fields.entries.joinToString(";") { "${it.key}=${it.value}" }
            .toByteArray(Charsets.UTF_8)

    fun decodeControl(payload: ByteArray): Map<String, String> =
        payload.toString(Charsets.UTF_8).split(";").filter { it.contains("=") }
            .associate { it.substringBefore("=") to it.substringAfter("=") }
}
