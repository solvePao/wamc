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
import com.androidwebcam.app.util.AppLog

/** Slight on-device sharpness + denoise level. Applied to preview and encoder alike. */
enum class EnhancementLevel {
    OFF,
    SLIGHT,
}

/** Pure mode-picking logic so unit tests can cover fallback without a camera. */
object EnhancementModes {
    fun pickEdgeMode(available: IntArray?, enabled: Boolean, lowLatency: Boolean = false): Int {
        if (!enabled) return CaptureRequest.EDGE_MODE_OFF
        if (available == null || available.isEmpty()) return CaptureRequest.EDGE_MODE_OFF
        if (lowLatency && available.contains(CaptureRequest.EDGE_MODE_FAST)) {
            return CaptureRequest.EDGE_MODE_FAST
        }
        if (available.contains(CaptureRequest.EDGE_MODE_HIGH_QUALITY)) {
            return CaptureRequest.EDGE_MODE_HIGH_QUALITY
        }
        if (available.contains(CaptureRequest.EDGE_MODE_FAST)) return CaptureRequest.EDGE_MODE_FAST
        if (available.contains(CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG)) {
            return CaptureRequest.EDGE_MODE_ZERO_SHUTTER_LAG
        }
        return CaptureRequest.EDGE_MODE_OFF
    }

    fun pickNoiseReductionMode(available: IntArray?, enabled: Boolean, lowLatency: Boolean = false): Int {
        if (!enabled) return CaptureRequest.NOISE_REDUCTION_MODE_OFF
        if (available == null || available.isEmpty()) return CaptureRequest.NOISE_REDUCTION_MODE_OFF
        if (lowLatency && available.contains(CaptureRequest.NOISE_REDUCTION_MODE_FAST)) {
            return CaptureRequest.NOISE_REDUCTION_MODE_FAST
        }
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
class CameraController internal constructor(
    context: Context,
    cameraInventory: List<CameraInfo>? = null,
    cameraOpenerOverride: CameraOpener? = null,
) : StreamingCamera {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val cameraOpener = cameraOpenerOverride ?: CameraOpener { id, callback, callbackHandler ->
        openCameraWithPermission(id, callback, callbackHandler)
    }
    private val thread = HandlerThread("camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val lifecycleLock = Any()
    @Volatile private var sessionGeneration = 0
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    override val availableCameras: List<CameraInfo> =
        cameraInventory ?: CameraClassifier.enumerateCameras(manager)

    private var lastSelectedBackCameraId: String? = null

    override var activeCameraId: String = determineDefaultCameraId()
        private set

    /** On-device enhance filter. True = slight sharpness + denoise via HAL. */
    override var enhancementEnabled: Boolean = true

    /** Wi-Fi low-latency: prefer FAST edge/noise modes over HIGH_QUALITY. */
    override var lowLatencyEnhancement: Boolean = false

    override val facingBack: Boolean
        get() {
            val cam = availableCameras.firstOrNull { it.id == activeCameraId }
            return cam?.facing != CameraCharacteristics.LENS_FACING_FRONT
        }

    init {
        if (facingBack) {
            lastSelectedBackCameraId = activeCameraId
        }
    }

    private fun determineDefaultCameraId(): String =
        DefaultCamera.pickId(availableCameras, null) ?: "0"

    override fun selectCamera(id: String) {
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

    override fun sensorOrientation(cameraId: String): Int =
        manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

    /** HAL rotate-and-crop modes the camera supports (empty when unsupported). */
    override fun rotateAndCropModes(cameraId: String): Set<Int> {
        if (android.os.Build.VERSION.SDK_INT < 31) return emptySet()
        return try {
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.SCALER_AVAILABLE_ROTATE_AND_CROP_MODES)
                ?.toSet().orEmpty()
        } catch (_: Exception) {
            emptySet()
        }
    }

    /** Largest encoder-supported size not exceeding the request (Samsung-safe). */
    override fun chooseSize(cameraId: String, wantW: Int, wantH: Int): Size {
        val map = manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
        return sizes.filter { it.width <= wantW && it.height <= wantH }
            .maxByOrNull { it.width.toLong() * it.height } ?: Size(1280, 720)
    }

    /** Reports async camera failures so owners can show status instead of dying. */
    override var openErrorListener: ((String) -> Unit)? = null
    override var rotationRejectedListener: ((String) -> Unit)? = null

    @SuppressLint("MissingPermission")
    private fun openCameraWithPermission(
        id: String,
        callback: CameraDevice.StateCallback,
        callbackHandler: Handler,
    ) = manager.openCamera(id, callback, callbackHandler)

    @SuppressLint("MissingPermission")
    override fun open(
        preview: Surface?,
        encoderSurface: Surface,
        wantW: Int,
        wantH: Int,
        halRotateMode: Int?,
    ) {
        val id = activeCameraId
        val onOpenError = openErrorListener
        val onRotationRejected = rotationRejectedListener
        closeSession()
        val generation = sessionGeneration
        try {
            cameraOpener.open(id, object : CameraDevice.StateCallback() {
                override fun onDisconnected(d: CameraDevice) {
                    runCatching { d.close() }
                        .onFailure { AppLog.warning("CameraController", "close after disconnect failed", it) }
                    AppLog.warning("CameraController", "camera $id disconnected")
                    if (generation == sessionGeneration) {
                        onOpenError?.invoke("camera disconnected")
                    }
                }
                override fun onError(d: CameraDevice, e: Int) {
                    runCatching { d.close() }
                        .onFailure { AppLog.warning("CameraController", "close after camera error failed", it) }
                    AppLog.error("CameraController", "camera $id reported error code=$e")
                    if (generation == sessionGeneration) {
                        onOpenError?.invoke("camera device error $e")
                    }
                }
                override fun onOpened(d: CameraDevice) {
                    if (generation != sessionGeneration) {
                        runCatching { d.close() }
                        return
                    }
                    try {
                        configureSession(d, preview, encoderSurface, id, halRotateMode, generation,
                            onOpenError, onRotationRejected)
                    } catch (t: Throwable) {
                        // Uncaught here would kill the process on the camera
                        // thread (e.g. abandoned Surface after rotation).
                        runCatching { d.close() }
                        AppLog.error("CameraController", "configure failed for camera $id", t)
                        onOpenError?.invoke("camera configure failed: ${t.message}")
                    }
                }
            }, handler)
        } catch (t: Throwable) {
            AppLog.error("CameraController", "open failed for camera $id", t)
            onOpenError?.invoke("camera open failed: ${t.message}")
        }
    }

    private fun configureSession(
        d: CameraDevice,
        preview: Surface?,
        encoderSurface: Surface,
        id: String,
        halRotateMode: Int?,
        generation: Int,
        onOpenError: ((String) -> Unit)?,
        onRotationRejected: ((String) -> Unit)?,
    ) {
        synchronized(lifecycleLock) {
            if (generation != sessionGeneration) {
                runCatching { d.close() }
                return
            }
            device = d
        }
        val edgeMode = resolveEdgeMode(id)
        val noiseMode = resolveNoiseReductionMode(id)
        val surfaces = listOfNotNull(preview, encoderSurface)
        @Suppress("DEPRECATION")
        d.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigureFailed(s: CameraCaptureSession) {
                runCatching { s.close() }
                    .onFailure { AppLog.warning("CameraController", "session close after configuration error failed", it) }
                AppLog.error("CameraController", "capture session configuration failed for camera $id")
                if (generation == sessionGeneration) {
                    if ((halRotateMode ?: 0) != 0) onRotationRejected?.invoke(id)
                    else onOpenError?.invoke("camera session configure failed")
                }
            }
            override fun onConfigured(s: CameraCaptureSession) {
                synchronized(lifecycleLock) {
                    if (generation != sessionGeneration) {
                        runCatching { s.close() }
                        return
                    }
                    session = s
                    try {
                        val req = d.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            surfaces.forEach { addTarget(it) }
                            set(CaptureRequest.CONTROL_AF_MODE,
                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                            set(CaptureRequest.CONTROL_AE_MODE,
                                CaptureRequest.CONTROL_AE_MODE_ON)
                            set(CaptureRequest.EDGE_MODE, edgeMode)
                            set(CaptureRequest.NOISE_REDUCTION_MODE, noiseMode)
                            // NONE is explicit too: AUTO can rotate buffers without
                            // updating our stream metadata.
                            if (halRotateMode != null &&
                                android.os.Build.VERSION.SDK_INT >= 31) {
                                set(CaptureRequest.SCALER_ROTATE_AND_CROP, halRotateMode)
                            }
                        }
                        val callback = object : CameraCaptureSession.CaptureCallback() {
                            private var checked = false
                            override fun onCaptureCompleted(
                                session: CameraCaptureSession, request: CaptureRequest,
                                result: android.hardware.camera2.TotalCaptureResult,
                            ) {
                                if (checked || generation != sessionGeneration) return
                                checked = true
                                if (halRotateMode != null && android.os.Build.VERSION.SDK_INT >= 31) {
                                    val actual = result.get(android.hardware.camera2.CaptureResult.SCALER_ROTATE_AND_CROP)
                                    if (actual != null && actual != halRotateMode) {
                                        runCatching { session.stopRepeating() }
                                        onRotationRejected?.invoke(id)
                                    }
                                }
                            }
                        }
                        s.setRepeatingRequest(req.build(), callback, handler)
                    } catch (t: Throwable) {
                        runCatching { s.close() }
                            .onFailure { AppLog.warning("CameraController", "session close after capture failure failed", it) }
                        AppLog.error("CameraController", "capture request failed for camera $id", t)
                        if (session === s) session = null
                        if (generation == sessionGeneration) {
                            if ((halRotateMode ?: 0) != 0) onRotationRejected?.invoke(id)
                            else onOpenError?.invoke("camera capture failed: ${t.message}")
                        }
                    }
                }
            }
        }, handler)
    }

    override fun switchCamera() {
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
        return EnhancementModes.pickEdgeMode(available, enhancementEnabled, lowLatencyEnhancement)
    }

    private fun resolveNoiseReductionMode(cameraId: String): Int {
        val available = runCatching {
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES)
        }.getOrNull()
        return EnhancementModes.pickNoiseReductionMode(available, enhancementEnabled, lowLatencyEnhancement)
    }

    /** Stops capture without killing the camera thread; call before tearing down surfaces. */
    override fun closeCapture() {
        closeSession()
    }

    private fun closeSession() {
        val oldSession: CameraCaptureSession?
        val oldDevice: CameraDevice?
        synchronized(lifecycleLock) {
            sessionGeneration += 1
            oldSession = session
            session = null
            oldDevice = device
            device = null
        }
        runCatching { oldSession?.close() }
            .onFailure { AppLog.warning("CameraController", "capture session close failed", it) }
        runCatching { oldDevice?.close() }
            .onFailure { AppLog.warning("CameraController", "camera device close failed", it) }
    }

    override fun close() {
        closeSession()
        thread.quitSafely()
    }
}

/** Camera2 open boundary for testing asynchronous callbacks without a device camera. */
internal fun interface CameraOpener {
    fun open(id: String, callback: CameraDevice.StateCallback, handler: Handler)
}
