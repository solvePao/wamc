package com.androidwebcam.app.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface

/** Slight on-device sharpness + denoise level. Applied to preview and encoder alike. */
enum class EnhancementLevel {
    OFF,
    SLIGHT,
}

/** Pure mode-picking logic so unit tests can cover fallback without a camera. */
object EnhancementModes {
    fun pickEdgeMode(available: IntArray?, enabled: Boolean): Int {
        if (!enabled) return CaptureRequest.EDGE_MODE_OFF
        if (available == null || available.isEmpty()) return CaptureRequest.EDGE_MODE_OFF
        if (available.contains(CaptureRequest.EDGE_MODE_HIGH_QUALITY)) {
            return CaptureRequest.EDGE_MODE_HIGH_QUALITY
        }
        if (available.contains(CaptureRequest.EDGE_MODE_FAST)) return CaptureRequest.EDGE_MODE_FAST
        if (available.contains(CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG)) {
            return CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG
        }
        return CaptureRequest.EDGE_MODE_OFF
    }

    fun pickNoiseReductionMode(available: IntArray?, enabled: Boolean): Int {
        if (!enabled) return CaptureRequest.NOISE_REDUCTION_MODE_OFF
        if (available == null || available.isEmpty()) return CaptureRequest.NOISE_REDUCTION_MODE_OFF
        if (available.contains(CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY)) {
            return CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY
        }
        if (available.contains(CaptureRequest.NOISE_REDUCTION_MODE_FAST)) {
            return CaptureRequest.NOISE_REDUCTION_MODE_FAST
        }
        if (available.contains(CaptureRequest.NOISE_REDUCTION_MODE_ZERO_SHUTTER_LAG)) {
            return CaptureRequest.NOISE_REDUCTION_MODE_ZERO_SHUTTER_LAG
        }
        return CaptureRequest.NOISE_REDUCTION_MODE_OFF
    }
}

/** Camera2 capture into encoder + preview surfaces with AF/AE left to the HAL. */
class CameraController(context: Context) {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("camera").apply { start() }
    private val handler = Handler(thread.looper)
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    val availableCameras: List<CameraInfo> = CameraClassifier.enumerateCameras(manager)

    private var lastSelectedBackCameraId: String? = null

    var activeCameraId: String = determineDefaultCameraId()
        private set

    /** On-device enhance filter. True = slight sharpness + denoise via HAL. */
    var enhancementEnabled: Boolean = true

    val facingBack: Boolean
        get() {
            val cam = availableCameras.firstOrNull { it.id == activeCameraId }
            return cam?.facing != CameraCharacteristics.LENS_FACING_FRONT
        }

    init {
        if (facingBack) {
            lastSelectedBackCameraId = activeCameraId
        }
    }

    private fun determineDefaultCameraId(): String {
        val mainBack = availableCameras.firstOrNull {
            it.facing == CameraCharacteristics.LENS_FACING_BACK && it.lensType == LensType.MAIN
        }
        val anyBack = availableCameras.firstOrNull {
            it.facing == CameraCharacteristics.LENS_FACING_BACK
        }
        val firstCam = availableCameras.firstOrNull()
        return mainBack?.id ?: anyBack?.id ?: firstCam?.id ?: "0"
    }

    fun selectCamera(id: String) {
        if (availableCameras.any { it.id == id }) {
            activeCameraId = id
            if (facingBack) {
                lastSelectedBackCameraId = id
            }
        }
    }

    fun cameraIds(): Pair<String?, String?> {
        val back = availableCameras.firstOrNull { it.id == activeCameraId && it.facing == CameraCharacteristics.LENS_FACING_BACK }?.id
            ?: availableCameras.firstOrNull { it.lensType == LensType.MAIN && it.facing == CameraCharacteristics.LENS_FACING_BACK }?.id
            ?: availableCameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_BACK }?.id
        val front = availableCameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_FRONT }?.id
        return back to front
    }

    fun sensorOrientation(cameraId: String): Int =
        manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

    /** HAL rotate-and-crop modes the camera supports (empty when unsupported). */
    fun rotateAndCropModes(cameraId: String): Set<Int> {
        if (android.os.Build.VERSION.SDK_INT < 33) return emptySet()
        return try {
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.SCALER_AVAILABLE_ROTATE_AND_CROP_MODES)
                ?.toSet().orEmpty()
        } catch (_: Exception) {
            emptySet()
        }
    }

    /** Largest encoder-supported size not exceeding the request (Samsung-safe). */
    fun chooseSize(cameraId: String, wantW: Int, wantH: Int): Size {
        val map = manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
        return sizes.filter { it.width <= wantW && it.height <= wantH }
            .maxByOrNull { it.width.toLong() * it.height } ?: Size(1280, 720)
    }

    /** Reports async camera failures so owners can show status instead of dying. */
    var openErrorListener: ((String) -> Unit)? = null

    @SuppressLint("MissingPermission")
    fun open(
        preview: Surface?,
        encoderSurface: Surface,
        wantW: Int,
        wantH: Int,
        halRotateMode: Int? = null,
    ) {
        val id = activeCameraId
        closeSession()
        try {
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onDisconnected(d: CameraDevice) { d.close() }
                override fun onError(d: CameraDevice, e: Int) {
                    d.close()
                    openErrorListener?.invoke("camera device error $e")
                }
                override fun onOpened(d: CameraDevice) {
                    try {
                        configureSession(d, preview, encoderSurface, id, halRotateMode)
                    } catch (t: Throwable) {
                        // Uncaught here would kill the process on the camera
                        // thread (e.g. abandoned Surface after rotation).
                        runCatching { d.close() }
                        openErrorListener?.invoke("camera configure failed: ${t.message}")
                    }
                }
            }, handler)
        } catch (t: Throwable) {
            openErrorListener?.invoke("camera open failed: ${t.message}")
        }
    }

    private fun configureSession(
        d: CameraDevice,
        preview: Surface?,
        encoderSurface: Surface,
        id: String,
        halRotateMode: Int?,
    ) {
        device = d
        val edgeMode = resolveEdgeMode(id)
        val noiseMode = resolveNoiseReductionMode(id)
        val surfaces = listOfNotNull(preview, encoderSurface)
        @Suppress("DEPRECATION")
        d.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigureFailed(s: CameraCaptureSession) {
                openErrorListener?.invoke("camera session configure failed")
            }
            override fun onConfigured(s: CameraCaptureSession) {
                session = s
                val req = d.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    surfaces.forEach { addTarget(it) }
                    set(CaptureRequest.CONTROL_AF_MODE,
                        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    set(CaptureRequest.CONTROL_AE_MODE,
                        CaptureRequest.CONTROL_AE_MODE_ON)
                    set(CaptureRequest.EDGE_MODE, edgeMode)
                    set(CaptureRequest.NOISE_REDUCTION_MODE, noiseMode)
                    // On-device rotation: the HAL rotates (and center-crops
                    // to the stream aspect) so the Mac needs no per-frame
                    // render. Null = unsupported, keep metadata rotation.
                    if (halRotateMode != null &&
                        android.os.Build.VERSION.SDK_INT >= 33) {
                        runCatching {
                            set(CaptureRequest.SCALER_ROTATE_AND_CROP, halRotateMode)
                        }
                    }
                }
                runCatching { s.setRepeatingRequest(req.build(), null, handler) }
            }
        }, handler)
    }

    fun switchCamera() {
        val frontCam = availableCameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_FRONT }
        val backCam = availableCameras.firstOrNull { it.id == lastSelectedBackCameraId }
            ?: availableCameras.firstOrNull { it.lensType == LensType.MAIN && it.facing == CameraCharacteristics.LENS_FACING_BACK }
            ?: availableCameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_BACK }
        if (facingBack) {
            frontCam?.let { selectCamera(it.id) }
        } else {
            backCam?.let { selectCamera(it.id) }
        }
    }

    fun setPreviewTransformHint(texture: SurfaceTexture, w: Int, h: Int) {
        // Preview rotation is cosmetic; the encoded stream keeps sensor order
        // and reports orientation in HELLO for the Mac side to rotate.
        texture.setDefaultBufferSize(w, h)
    }

    private fun resolveEdgeMode(cameraId: String): Int {
        val available = runCatching {
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES)
        }.getOrNull()
        return EnhancementModes.pickEdgeMode(available, enhancementEnabled)
    }

    private fun resolveNoiseReductionMode(cameraId: String): Int {
        val available = runCatching {
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES)
        }.getOrNull()
        return EnhancementModes.pickNoiseReductionMode(available, enhancementEnabled)
    }

    /** Stops capture without killing the camera thread; call before tearing down surfaces. */
    fun closeCapture() {
        closeSession()
    }

    private fun closeSession() {
        runCatching { session?.close() }; session = null
        runCatching { device?.close() }; device = null
    }

    fun close() {
        closeSession()
        thread.quitSafely()
    }
}
