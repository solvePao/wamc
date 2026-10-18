package com.androidwebcam.app.camera

import android.content.Context
import android.util.Size
import android.view.Surface

/** Narrow hardware boundary used by the service and deterministic pipeline tests. */
internal interface StreamingCamera {
    val availableCameras: List<CameraInfo>
    val activeCameraId: String
    val facingBack: Boolean
    var enhancementEnabled: Boolean
    var lowLatencyEnhancement: Boolean
    var openErrorListener: ((String) -> Unit)?
    var rotationRejectedListener: ((String) -> Unit)?
    fun selectCamera(id: String)
    fun switchCamera()
    fun sensorOrientation(cameraId: String): Int
    fun rotateAndCropModes(cameraId: String): Set<Int>
    fun chooseSize(cameraId: String, wantW: Int, wantH: Int): Size
    fun open(preview: Surface?, encoderSurface: Surface, wantW: Int, wantH: Int, halRotateMode: Int?)
    fun closeCapture()
    fun close()
}

internal fun interface StreamingCameraFactory {
    fun create(context: Context): StreamingCamera
}

internal interface StreamingEncoder {
    val inputSurface: Surface
    fun start()
    fun requestKeyframe()
    fun stop()
}

internal fun interface StreamingEncoderFactory {
    fun create(
        profile: StreamProfile,
        lowLatency: Boolean,
        onConfig: (ByteArray, ByteArray) -> Unit,
        onConfigSets: (List<ByteArray>) -> Unit,
        onFrame: (ByteArray, Boolean, Long) -> Unit,
    ): StreamingEncoder
}
