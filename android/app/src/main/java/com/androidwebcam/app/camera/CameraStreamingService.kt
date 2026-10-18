package com.androidwebcam.app.camera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.view.Surface
import android.view.WindowManager
import com.androidwebcam.app.protocol.WireProtocol
import com.androidwebcam.app.transport.AdbSocketTransport
import com.androidwebcam.app.transport.NativeUvcSupport
import com.androidwebcam.app.transport.TransportHub
import com.androidwebcam.app.transport.UsbAccessoryTransport

/** Foreground service owning camera + encoder + transports while streaming. */
class CameraStreamingService : Service() {

    inner class LocalBinder : Binder() {
        fun service(): CameraStreamingService = this@CameraStreamingService
    }

    private val binder = LocalBinder()
    private val hub = TransportHub()
    private lateinit var adbTransport: AdbSocketTransport
    private lateinit var aoaTransport: UsbAccessoryTransport
    private var camera: CameraController? = null
    private var encoder: VideoEncoder? = null
    private var previewSurface: Surface? = null
    private var lastConfig: ByteArray? = null

    private val prefs by lazy { getSharedPreferences("wamc_prefs", MODE_PRIVATE) }
    private var savedCameraId: String? = null
    var enhancementEnabled: Boolean = true
        private set

    var streaming = false
        private set
    var statusListener: ((String) -> Unit)? = null
    var rotationListener: ((Int) -> Unit)? = null
    var cameraChangeListener: ((String) -> Unit)? = null

    /** Quarter-turns clockwise (0..3); reflected in CONFIG and on the Mac. */
    var rotationQuarterTurns = 0
        private set
    private var width = 1920
    private var height = 1080
    private var fps = 30
    private var quality = StreamQuality.BEST
    private var requestedCodec = "auto"
    private var bitrateOverrideBps: Int? = null
    private var gopOverrideSec: Int? = null
    private var peerCodecs: List<Int>? = null
    private var lastSps: ByteArray? = null
    private var lastPps: ByteArray? = null
    private var lastParamSets: List<ByteArray>? = null
    private var lastCodec = QualitySelector.AVC
    /** Codec chosen by the latest pipeline (pre-CONFIG, so hello can compare). */
    private var activeCodec = QualitySelector.AVC
    private var lastWidth = 0
    private var lastHeight = 0
    private var lastSentSets: List<ByteArray>? = null
    private var lastSentCodec = -1
    private var lastSentWidth = 0
    private var lastSentHeight = 0
    private var lastSentRotation = -1

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Started (not only bound): idle-listen so the Mac can always signal,
        // and restart sticky if the process dies.
        // Foreground only when allowed: without the CAMERA grant (fresh
        // install) or an eligible state, startForeground() on our manifest
        // camera-type service throws SecurityException — listen
        // unforegrounded instead of crash-looping; streaming foregrounds
        // once the app is opened and eligible.
        if (hasCameraPermission()) {
            runCatching { showIdleNotification() }.onFailure {
                android.util.Log.w("AWC", "idle foreground refused; listening backgrounded", it)
            }
        }
        return START_STICKY
    }

    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    override fun onCreate() {
        super.onCreate()
        savedCameraId = prefs.getString(PREF_CAMERA_ID, null)
        enhancementEnabled = prefs.getBoolean(PREF_ENHANCE, true)
        quality = StreamQuality.parse(prefs.getString(PREF_QUALITY, StreamQuality.BEST.key))
        adbTransport = AdbSocketTransport(hub)
        aoaTransport = UsbAccessoryTransport(this, hub)
        hub.onPeerAttached = {
            sendHello()
            resendConfig()
            encoder?.requestKeyframe()
        }
        val onControl: (Map<String, String>) -> Unit = { handleControl(it) }
        adbTransport.start(onControl)
        aoaTransport.start(onControl)
    }

    fun getAvailableCameras(): List<CameraInfo> {
        return camera?.availableCameras
            ?: getSystemService(android.hardware.camera2.CameraManager::class.java)?.let {
                CameraClassifier.enumerateCameras(it)
            } ?: emptyList()
    }

    val currentCameraId: String
        get() = camera?.activeCameraId
            ?: DefaultCamera.pickId(getAvailableCameras(), savedCameraId)
            ?: "0"

    fun selectCamera(cameraId: String) {
        savedCameraId = cameraId
        prefs.edit().putString(PREF_CAMERA_ID, cameraId).apply()
        camera?.selectCamera(cameraId)
        cameraChangeListener?.invoke(cameraId)
        if (streaming) restartPipeline()
    }

    fun setPreviewSurface(surface: Surface?) {
        previewSurface = surface
        if (streaming) restartPipeline()
    }

    fun setEnhancementEnabled(enabled: Boolean) {
        if (enhancementEnabled == enabled) return
        enhancementEnabled = enabled
        prefs.edit().putBoolean(PREF_ENHANCE, enabled).apply()
        camera?.enhancementEnabled = enabled
        if (streaming) restartPipeline()
    }

    fun connectAccessory() {
        aoaTransport.start { handleControl(it) }
    }

    fun startStreaming(
        wantW: Int, wantH: Int, wantFps: Int = 30,
        wantQuality: StreamQuality = StreamQuality.BEST,
    ) {
        width = wantW; height = wantH; fps = wantFps
        quality = wantQuality
        prefs.edit().putString(PREF_QUALITY, quality.key).apply()
        startForegroundNotification()
        restartPipeline()
        streaming = true
        emitStatus()
    }

    fun setQuality(q: StreamQuality) {
        quality = q
        prefs.edit().putString(PREF_QUALITY, q.key).apply()
        if (streaming) restartPipeline()
    }

    fun stopStreaming() {
        streaming = false
        // Same ordering as restart: halt capture before releasing surfaces.
        camera?.closeCapture()
        encoder?.stop(); encoder = null
        camera?.close(); camera = null
        // Back to idle listener (service stays started); streaming needs a trigger.
        // A Mac-commanded stop can arrive while backgrounded/ineligible, where
        // foregrounding throws — never let that escape the reader thread.
        runCatching { showIdleNotification() }
        emitStatus()
    }

    fun switchCamera() {
        val controller = camera ?: CameraController(this).also {
            camera = it
            savedCameraId?.let { id -> it.selectCamera(id) }
        }
        controller.switchCamera()
        val newId = controller.activeCameraId
        savedCameraId = newId
        prefs.edit().putString(PREF_CAMERA_ID, newId).apply()
        cameraChangeListener?.invoke(newId)
        if (streaming) restartPipeline()
    }

    /** Manual taps on top of sensor/display compensation; Mac renders the total. */
    fun rotate() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        resendConfig()
        encoder?.requestKeyframe()
        rotationListener?.invoke(previewTurns())
    }

    fun setRotation(quarterTurns: Int) {
        rotationQuarterTurns = quarterTurns and 3
        resendConfig()
        encoder?.requestKeyframe()
        rotationListener?.invoke(previewTurns())
    }

    /** Preview matrix turns: HAL output is already upright, else match the Mac. */
    fun previewTurns(): Int = rotationSetup().previewTurns

    private data class RotationSetup(
        val halMode: Int?,
        val macRotation: Int,
        val previewTurns: Int,
    )

    /**
     * Total orientation = sensor/display/facing compensation plus manual taps.
     * HAL rotates on-device when supported (preview and encoder arrive upright);
     * otherwise the total travels in CONFIG and the Mac renders it.
     */
    private fun rotationSetup(): RotationSetup {
        val controller = camera
            ?: return RotationSetup(null, rotationQuarterTurns, rotationQuarterTurns)
        val sensor = runCatching {
            controller.sensorOrientation(controller.activeCameraId)
        }.getOrDefault(0)
        val total = CameraOrientation.totalTurns(
            sensor, deviceDegrees(), !controller.facingBack, rotationQuarterTurns)
        val plan = RotationPlanner.plan(
            total, controller.rotateAndCropModes(controller.activeCameraId))
        val preview = if (plan.halRotateMode != null) 0 else total
        return RotationSetup(plan.halRotateMode, plan.configRotation, preview)
    }

    private fun deviceDegrees(): Int = runCatching {
        val wm = getSystemService(WindowManager::class.java) ?: return 0
        @Suppress("DEPRECATION")
        when (wm.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }.getOrDefault(0)

    private fun resendConfig() {
        val sets = lastParamSets ?: return
        if (lastWidth == 0 || sets.size < 2) return
        val effectiveRotation = rotationSetup().macRotation
        hub.sendConfigV2(WireProtocol.encodeConfigV2(
            lastCodec, sets, lastWidth, lastHeight, fps, effectiveRotation))
        lastSentSets = sets; lastSentCodec = lastCodec
        lastSentWidth = lastWidth; lastSentHeight = lastHeight
        lastSentRotation = effectiveRotation
        if (lastCodec == WireProtocol.CODEC_AVC) {
            lastConfig = WireProtocol.encodeConfig(
                sets[sets.size - 2], sets[sets.size - 1],
                lastWidth, lastHeight, fps, effectiveRotation)
            hub.sendConfig(lastConfig!!)
        }
    }

    val currentQuality: StreamQuality get() = quality

    fun isBackFacing(): Boolean = camera?.facingBack
        ?: (getAvailableCameras().firstOrNull { it.id == currentCameraId }?.facing !=
            android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT)
    fun peerCount(): Int = hub.peerCount()
    fun uvcGuidance(): String = NativeUvcSupport.guidance()

    private fun restartPipeline() {
        try {
            restartPipelineUnsafe()
        } catch (t: Throwable) {
            android.util.Log.e("AWC", "pipeline restart failed", t)
            encoder = null
            emitStatus("Camera unavailable: ${t.message}")
        }
    }

    private fun restartPipelineUnsafe() {
        // Stop capture BEFORE releasing the encoder surface: the camera must
        // never target a released surface (HAL buffer errors / session death).
        camera?.closeCapture()
        encoder?.stop()
        encoder = null
        val controller = camera ?: CameraController(this).also { camera = it }
        controller.openErrorListener = { msg -> emitStatus("Camera unavailable: $msg") }
        controller.enhancementEnabled = enhancementEnabled
        savedCameraId?.let { controller.selectCamera(it) }
        val size = controller.chooseSize(controller.activeCameraId, width, height)
        val phoneCodecs = EncoderCaps.supportedCodecs()
        val codec = QualitySelector.pickCodec(requestedCodec, phoneCodecs, peerCodecs)
        activeCodec = codec
        val profile = QualitySelector.profileFor(
            quality, codec, size.width, size.height, fps,
            bitrateOverrideBps, gopOverrideSec)
        android.util.Log.i("AWC",
            "pipeline: codec=${if (codec == 1) "hevc" else "avc"} " +
                "quality=${quality.key} ${profile.width}x${profile.height}@${profile.fps} " +
                "${profile.bitrateBps / 1_000_000}Mbps gop=${profile.iFrameIntervalSec}s " +
                "(want=$requestedCodec phone=$phoneCodecs peer=$peerCodecs)")
        val rs = rotationSetup()
        val enc = VideoEncoder(profile,
            onConfig = { sps, pps ->
                lastSps = sps; lastPps = pps
                lastWidth = size.width; lastHeight = size.height
            },
            onConfigSets = { sets ->
                val rotation = rs.macRotation
                val duplicate = lastSentSets?.let { prev ->
                    prev.size == sets.size &&
                        prev.zip(sets).all { (a, b) -> a.contentEquals(b) }
                } == true && lastSentWidth == size.width && lastSentHeight == size.height &&
                    lastSentRotation == rotation && lastSentCodec == codec
                lastParamSets = sets; lastCodec = codec
                lastWidth = size.width; lastHeight = size.height
                if (!duplicate) {
                    lastSentSets = sets; lastSentCodec = codec
                    lastSentWidth = size.width; lastSentHeight = size.height
                    lastSentRotation = rotation
                    // CONFIG2 first (new Macs); legacy CONFIG keeps old Macs alive on AVC.
                    hub.sendConfigV2(WireProtocol.encodeConfigV2(
                        codec, sets, size.width, size.height, fps, rotation))
                    if (codec == WireProtocol.CODEC_AVC) {
                        lastConfig = WireProtocol.encodeConfig(
                            sets[sets.size - 2], sets[sets.size - 1],
                            size.width, size.height, fps, rotation)
                        hub.sendConfig(lastConfig!!)
                    }
                }
            },
            onFrame = { data, isKey, pts -> hub.sendVideo(data, isKey, pts) })
        encoder = enc
        enc.start()
        controller.open(previewSurface, enc.inputSurface, width, height, rs.halMode)
        rotationListener?.invoke(rs.previewTurns)
        sendHello()
        emitStatus()
    }

    private fun handleControl(fields: Map<String, String>) {
        when (fields["cmd"]) {
            "hello" -> {
                // Mac capability announcement; never starts streaming by itself.
                // Restart a live stream only when the new caps would actually
                // switch the codec — otherwise this is just a reconnect ping
                // and a restart would churn surfaces for nothing.
                peerCodecs = QualitySelector.parsePeerCodecs(fields["codecs"])
                if (streaming) {
                    val better = QualitySelector.pickCodec(
                        requestedCodec, EncoderCaps.supportedCodecs(), peerCodecs)
                    if (better != activeCodec) restartPipeline()
                }
            }
            "start" -> {
                requestedCodec = fields["codec"] ?: "auto"
                quality = StreamQuality.parse(fields["quality"])
                bitrateOverrideBps = fields["bitrate"]?.toIntOrNull()
                gopOverrideSec = fields["gop"]?.toIntOrNull()
                QualitySelector.parsePeerCodecs(fields["codecs"])?.let { peerCodecs = it }
                startStreaming(
                    fields["width"]?.toIntOrNull() ?: width,
                    fields["height"]?.toIntOrNull() ?: height,
                    fields["fps"]?.toIntOrNull() ?: fps,
                    quality)
            }
            "stop" -> stopStreaming()
            "requestKeyframe" -> encoder?.requestKeyframe()
            "setFacing" -> {
                val wantBack = fields["facing"] != "front"
                if (isBackFacing() != wantBack) switchCamera()
            }
            "setCamera" -> fields["cameraId"]?.let { selectCamera(it) }
            "setRotation" -> fields["rotation"]?.toIntOrNull()?.let { setRotation(it) }
            "rotate" -> rotate()
            "ping" -> Unit // reader liveness only
        }
    }

    private fun sendHello() {
        val controller = camera ?: return
        val (back, front) = controller.cameraIds()
        val cameras = listOfNotNull(
            if (back != null) "back" else null,
            if (front != null) "front" else null).joinToString(",")
        val hello = WireProtocol.encodeControl(mapOf(
            "model" to Build.MODEL, "brand" to Build.BRAND,
            "sdk" to Build.VERSION.SDK_INT.toString(),
            "cameras" to cameras, "uvc" to "unknown",
            "codecs" to EncoderCaps.csv(), "configV2" to "1"))
        hub.sendHello(hello)
    }

    private fun emitStatus(note: String? = null) {
        val state = when {
            note != null -> note
            !streaming -> "Not streaming"
            hub.peerCount() > 0 -> "Streaming to Mac (${hub.peerCount()} connection)"
            else -> "Streaming — waiting for Mac on USB"
        }
        statusListener?.invoke(state)
    }

    private fun notification(text: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Camera streaming", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("WAMC")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .build()
    }

    /** Idle listener: no camera, so no camera service type claimed. */
    private fun showIdleNotification() {
        startForeground(ID, notification("WAMC ready — connect USB to stream to your Mac"))
    }

    private fun startForegroundNotification() {
        val notification = notification("Camera is streaming to your Mac")
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            @Suppress("DEPRECATION") startForeground(ID, notification)
        }
    }

    override fun onDestroy() {
        stopStreaming()
        adbTransport.close()
        aoaTransport.close()
        hub.closeAll()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "streaming"
        private const val ID = 1
        private const val PREF_CAMERA_ID = "selected_camera_id"
        private const val PREF_ENHANCE = "enhance_enabled"
        private const val PREF_QUALITY = "stream_quality"
    }
}
