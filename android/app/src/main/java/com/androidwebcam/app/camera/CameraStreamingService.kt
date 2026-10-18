package com.androidwebcam.app.camera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import android.view.WindowManager
import com.androidwebcam.app.protocol.WireProtocol
import com.androidwebcam.app.transport.AdbSocketTransport
import com.androidwebcam.app.transport.DiscoveryConfig
import com.androidwebcam.app.transport.NativeUvcSupport
import com.androidwebcam.app.transport.TransportHub
import com.androidwebcam.app.transport.UsbAccessoryTransport
import com.androidwebcam.app.transport.WamcDiscovery
import com.androidwebcam.app.transport.WifiDiscoveryAdvertiser
import com.androidwebcam.app.util.AppLog

internal enum class RemoteStartDecision { START, QUEUE_FOR_VISIBLE_ACTIVITY }

internal object CameraStartPolicy {
    const val OPEN_APP_STATUS = "Open WAMC on the phone to start the camera"

    fun remoteStartDecision(activityVisible: Boolean): RemoteStartDecision =
        if (activityVisible) RemoteStartDecision.START
        else RemoteStartDecision.QUEUE_FOR_VISIBLE_ACTIVITY
}

/** Foreground service owning camera + encoder + transports while streaming. */
class CameraStreamingService : Service() {

    inner class LocalBinder : Binder() {
        fun service(): CameraStreamingService = this@CameraStreamingService
    }

    private val binder = LocalBinder()
    private val hub = TransportHub()
    private lateinit var adbTransport: AdbSocketTransport
    private lateinit var aoaTransport: UsbAccessoryTransport
    private var wifiAdvertiser: WifiDiscoveryAdvertiser? = null

    /** Bonjour Wi-Fi discovery. Default ON, persisted, switchable in UI. */
    var wifiDiscoveryEnabled: Boolean = true
        private set
    var wifiDiscoveryChangeListener: ((Boolean) -> Unit)? = null
    internal var cameraFactory = StreamingCameraFactory { context -> CameraController(context) }
    internal var encoderFactory = StreamingEncoderFactory { profile, lowLatency, onConfig, onConfigSets, onFrame ->
        VideoEncoder(profile, onConfig, onConfigSets, onFrame, lowLatency)
    }
    private var camera: StreamingCamera? = null
    private var encoder: StreamingEncoder? = null
    private var previewSurface: Surface? = null
    private var lastConfig: ByteArray? = null

    private val prefs by lazy { getSharedPreferences("wamc_prefs", MODE_PRIVATE) }
    private var savedCameraId: String? = null
    var enhancementEnabled: Boolean = true
        private set

    var streaming = false
        private set
    @Volatile private var activityVisible = false
    private var pendingStart: PendingStart? = null
    private var lastErrorStatus: String? = null
    var statusListener: ((String) -> Unit)? = null
    var rotationListener: ((PreviewOrientation) -> Unit)? = null
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
    /** Wi-Fi low-latency profile requested by the Mac (`latency=low`). */
    private var lowLatencyWifi = false
    private var peerCodecs: List<Int>? = null
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
    /** Monotonic restart epoch, echoed in HELLO so the Mac can tell rejoins apart. */
    var streamGeneration = 0
        private set
    private val restartGate = RestartGate()
    /** requestKeyframe that arrived while the encoder was down. */
    private var pendingKeyframeRequest = false
    private val mainHandler by lazy { Handler(mainLooper) }
    private val rotationSchedule = RotationUpdateSchedule(ROTATION_DEBOUNCE_MS)
    private var appliedOrientation: StreamOrientation? = null
    private val metadataOnlyCameras = mutableSetOf<String>()
    private val rotationUpdate = Runnable { updateOrientation() }
    private var displayManager: DisplayManager? = null
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            scheduleRotationUpdate()
        }
    }

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
            onMain {
                sendHello()
                resendConfig()
                encoder?.requestKeyframe()
            }
        }
        val onControl: (Map<String, String>) -> Unit = { fields -> onMain { handleControl(fields) } }
        adbTransport.start(onControl)
        aoaTransport.start(onControl)
        wifiDiscoveryEnabled = prefs.getBoolean(PREF_WIFI_DISCOVERY, true)
        wifiAdvertiser = WifiDiscoveryAdvertiser(this) {
            DiscoveryConfig(
                id = deviceId(),
                model = Build.MODEL ?: "Android",
                brand = Build.BRAND ?: "",
                sdk = Build.VERSION.SDK_INT,
            )
        }
        if (wifiDiscoveryEnabled) wifiAdvertiser?.start()
        displayManager = runCatching { getSystemService(DisplayManager::class.java) }.getOrNull()
        runCatching {
            displayManager?.registerDisplayListener(displayListener, Handler(mainLooper))
        }
    }

    /** Stable per-install identity for Bonjour + HELLO. Never rotates. */
    fun deviceId(): String {
        prefs.getString(PREF_DEVICE_ID, null)
            ?.takeIf { WamcDiscovery.isValidId(it) }
            ?.let { return it }
        val fresh = WamcDiscovery.newDeviceId()
        prefs.edit().putString(PREF_DEVICE_ID, fresh).apply()
        return fresh
    }

    fun setWifiDiscoveryEnabled(enabled: Boolean) {
        if (wifiDiscoveryEnabled == enabled) return
        wifiDiscoveryEnabled = enabled
        prefs.edit().putBoolean(PREF_WIFI_DISCOVERY, enabled).apply()
        if (enabled) wifiAdvertiser?.start() else wifiAdvertiser?.stop()
        wifiDiscoveryChangeListener?.invoke(enabled)
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
        if (surface == null) {
            // Transient teardown (rotation, backgrounding): stop feeding the
            // dead surface without rebuilding the encoder; the next live
            // surface triggers the single restart.
            if (streaming) camera?.closeCapture()
            return
        }
        if (streaming) restartPipeline()
    }

    /** Activity config changes and display rotation funnel here. */
    fun notifyConfigurationChanged() {
        scheduleRotationUpdate()
    }

    private fun scheduleRotationUpdate() {
        mainHandler.removeCallbacks(rotationUpdate)
        mainHandler.postDelayed(rotationUpdate, rotationSchedule.delayMs(SystemClock.uptimeMillis()))
    }

    private fun updateOrientation() {
        val desired = rotationSetup()
        val previous = appliedOrientation
        if (!streaming || previous == null) {
            rotationListener?.invoke(desired.preview)
            return
        }
        rotationSchedule.didApply(SystemClock.uptimeMillis())
        when (RotationResendPolicy.decide(
            previous.halMode, previous.streamTurns,
            desired.halMode, desired.streamTurns, hasConfig = true)) {
            RotationResendPolicy.Action.RESTART -> restartPipeline()
            else -> {
                appliedOrientation = desired
                rotationListener?.invoke(desired.preview)
                if (previous.streamTurns != desired.streamTurns) {
                    hub.flushVideo()
                    restartGate.reset()
                    resendConfig()
                    encoder?.requestKeyframe()
                }
            }
        }
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == mainLooper) action() else mainHandler.post { action() }
    }

    fun setEnhancementEnabled(enabled: Boolean) {
        if (enhancementEnabled == enabled) return
        enhancementEnabled = enabled
        prefs.edit().putBoolean(PREF_ENHANCE, enabled).apply()
        camera?.enhancementEnabled = enabled
        if (streaming) restartPipeline()
    }

    fun connectAccessory() {
        aoaTransport.start { fields -> onMain { handleControl(fields) } }
    }

    fun startStreaming(
        wantW: Int, wantH: Int, wantFps: Int = 30,
        wantQuality: StreamQuality = StreamQuality.BEST,
    ): Boolean {
        if (com.androidwebcam.app.update.AndroidUpdates.get(this).installationInProgress) {
            pendingStart = null
            emitStatus("Finish the update installation before starting streaming.")
            return false
        }
        if (!streaming && CameraStartPolicy.remoteStartDecision(activityVisible) != RemoteStartDecision.START) {
            pendingStart = PendingStart(wantW, wantH, wantFps, wantQuality)
            emitStatus(CameraStartPolicy.OPEN_APP_STATUS)
            return false
        }
        width = wantW; height = wantH; fps = wantFps
        quality = wantQuality
        prefs.edit().putString(PREF_QUALITY, quality.key).apply()
        try {
            startForegroundNotification()
        } catch (t: Throwable) {
            lastErrorStatus = "Camera service start denied: ${t.message ?: t.javaClass.simpleName}"
            emitStatus(lastErrorStatus)
            return false
        }
        lastErrorStatus = null
        streaming = true
        if (!restartPipeline()) {
            streaming = false
            runCatching { showIdleNotification() }
            return false
        }
        emitStatus()
        return true
    }

    /** Activity lifecycle is the Android 14+ camera foreground-service gate. */
    fun setActivityVisible(visible: Boolean) {
        activityVisible = visible
    }

    /** Called only by the resumed Activity; remote starts never launch UI. */
    fun startPendingRequest(): Boolean {
        val request = pendingStart ?: return false
        pendingStart = null
        return startStreaming(request.width, request.height, request.fps, request.quality)
    }

    private data class PendingStart(
        val width: Int, val height: Int, val fps: Int, val quality: StreamQuality,
    )

    fun setQuality(q: StreamQuality) {
        quality = q
        prefs.edit().putString(PREF_QUALITY, q.key).apply()
        if (streaming) restartPipeline()
    }

    fun stopStreaming() {
        mainHandler.removeCallbacks(rotationUpdate)
        appliedOrientation = null
        pendingStart = null
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
            val controller = camera ?: cameraFactory.create(this).also {
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
        setRotation(rotationQuarterTurns + 1)
    }

    fun setRotation(quarterTurns: Int) {
        rotationQuarterTurns = quarterTurns and 3
        mainHandler.removeCallbacks(rotationUpdate)
        updateOrientation()
    }

    fun previewOrientation(): PreviewOrientation =
        appliedOrientation?.preview ?: rotationSetup().preview

    /**
     * Total orientation = sensor/display/facing compensation plus manual taps.
     * HAL rotates encoder buffers when supported; otherwise the total travels
     * in CONFIG. TextureView receives a separate residual transform.
     */
    private fun rotationSetup(): StreamOrientation {
        val controller = camera
        val id = controller?.activeCameraId ?: currentCameraId
        val sensor = runCatching {
            controller?.sensorOrientation(id) ?: 0
        }.getOrDefault(0)
        val modes = controller?.rotateAndCropModes(id).orEmpty()
        val allowedModes = if (id in metadataOnlyCameras) modes.intersect(setOf(0)) else modes
        return StreamOrientation.create(id, streamGeneration, sensor, deviceDegrees(),
            !isBackFacing(), rotationQuarterTurns, allowedModes)
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

    private fun resendConfig(force: Boolean = true) {
        val sets = lastParamSets ?: return
        if (lastWidth == 0 || sets.size < 2) return
        val effectiveRotation = appliedOrientation?.streamTurns ?: return
        if (!force && lastSentCodec == lastCodec && lastSentWidth == lastWidth &&
            lastSentHeight == lastHeight && lastSentRotation == effectiveRotation &&
            lastSentSets?.let { previous -> previous.size == sets.size &&
                previous.zip(sets).all { (a, b) -> a.contentEquals(b) } } == true) return
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

    private fun restartPipeline(): Boolean {
        try {
            restartPipelineUnsafe()
            lastErrorStatus = null
            return true
        } catch (t: Throwable) {
            AppLog.error("CameraStreamingService", "pipeline restart failed", t)
            encoder = null
            val reason = t.message ?: t.javaClass.simpleName
            lastErrorStatus = "Encoder failed: $reason"
            emitStatus(lastErrorStatus)
            return false
        }
    }

    private fun restartPipelineUnsafe() {
        // New epoch: flush stale VIDEO so it can never sit ahead of the new
        // CONFIG in TCP order, then gate frames until the first IDR.
        streamGeneration = StreamGeneration.next(streamGeneration)
        appliedOrientation = null
        hub.flushVideo()
        restartGate.reset()
        // Stop capture BEFORE releasing the encoder surface: the camera must
        // never target a released surface (HAL buffer errors / session death).
        camera?.closeCapture()
        encoder?.stop()
        encoder = null
        val controller = camera ?: cameraFactory.create(this).also { camera = it }
        savedCameraId?.let { controller.selectCamera(it) }
        val generation = streamGeneration
        val cameraId = controller.activeCameraId
        controller.openErrorListener = { msg ->
            onMain {
                if (appliedOrientation?.belongsTo(cameraId, generation) == true) {
                    lastErrorStatus = "Camera open failed: $msg"
                    emitStatus(lastErrorStatus)
                }
            }
        }
        controller.rotationRejectedListener = { rejectedCamera ->
            // Camera callbacks run on the camera thread; rebuild only the still-live generation.
            mainHandler.post {
                val current = appliedOrientation
                if (current?.belongsTo(rejectedCamera, generation) == true) {
                    if (current.halMode != 0 && metadataOnlyCameras.add(rejectedCamera)) {
                        AppLog.warning("CameraStreamingService", "HAL rotation rejected on $rejectedCamera; using metadata")
                        restartPipeline()
                    } else {
                        stopStreaming()
                        lastErrorStatus = "Camera cannot disable automatic rotation"
                        emitStatus(lastErrorStatus)
                    }
                }
            }
        }
        controller.enhancementEnabled = enhancementEnabled
        controller.lowLatencyEnhancement = lowLatencyWifi
        val size = controller.chooseSize(controller.activeCameraId, width, height)
        val phoneCodecs = EncoderCaps.supportedCodecs()
        val codec = QualitySelector.pickCodec(requestedCodec, phoneCodecs, peerCodecs)
        activeCodec = codec
        val profile = QualitySelector.profileFor(
            quality, codec, size.width, size.height, fps,
            bitrateOverrideBps, gopOverrideSec, lowLatency = lowLatencyWifi)
        AppLog.info("CameraStreamingService",
            "pipeline: codec=${if (codec == 1) "hevc" else "avc"} " +
                "quality=${quality.key} ${profile.width}x${profile.height}@${profile.fps} " +
                "${profile.bitrateBps / 1_000_000}Mbps gop=${profile.iFrameIntervalSec}s " +
                "latency=${if (lowLatencyWifi) "wifi-low" else "standard"} " +
                "(want=$requestedCodec phone=$phoneCodecs peer=$peerCodecs)")
        val orientation = rotationSetup()
        appliedOrientation = orientation
        lastParamSets = null
        lastSentSets = null
        lastConfig = null
        lastWidth = 0; lastHeight = 0
        val enc = encoderFactory.create(profile, lowLatencyWifi,
            onConfig = { _, _ -> Unit },
            onConfigSets = { sets ->
                onMain {
                    if (appliedOrientation?.belongsTo(orientation.cameraId, generation) == true) {
                        lastParamSets = sets; lastCodec = codec
                        lastWidth = size.width; lastHeight = size.height
                        resendConfig(force = false)
                    }
                }
            },
            onFrame = { data, isKey, pts ->
                onMain {
                    if (appliedOrientation?.belongsTo(orientation.cameraId, generation) == true &&
                        lastParamSets != null && restartGate.shouldForward(isKey)) {
                        hub.sendVideo(data, isKey, pts)
                    }
                }
            },
        )
        encoder = enc
        sendHello()
        enc.start()
        // Force the opening IDR instead of waiting up to a full GOP. Also
        // coalesces any requestKeyframe that arrived while the encoder was down.
        pendingKeyframeRequest = false
        enc.requestKeyframe()
        controller.open(previewSurface, enc.inputSurface, width, height, orientation.halMode)
        rotationListener?.invoke(orientation.preview)
        rotationSchedule.didApply(SystemClock.uptimeMillis())
        emitStatus()
    }

    internal fun handleControl(fields: Map<String, String>) {
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
                // Transport-aware profile: the Mac marks Wi-Fi starts with
                // latency=low (75% bitrate, GOP 1); USB starts omit it.
                lowLatencyWifi = fields["latency"] == "low"
                QualitySelector.parsePeerCodecs(fields["codecs"])?.let { peerCodecs = it }
                val requested = PendingStart(
                    fields["width"]?.toIntOrNull() ?: width,
                    fields["height"]?.toIntOrNull() ?: height,
                    fields["fps"]?.toIntOrNull() ?: fps,
                    quality)
                startStreaming(requested.width, requested.height, requested.fps, requested.quality)
            }
            "stop" -> stopStreaming()
            "requestKeyframe" -> {
                if (encoder != null) encoder?.requestKeyframe()
                else pendingKeyframeRequest = true
            }
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
        // Works idle too (no camera yet): enumerate without opening it so a
        // Wi-Fi Mac can verify TXT id == HELLO id before streaming starts.
        val available = camera?.availableCameras ?: getAvailableCameras()
        val hasBack = available.any {
            it.facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
        }
        val hasFront = available.any {
            it.facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
        }
        val cameras = listOfNotNull(
            if (hasBack) "back" else null,
            if (hasFront) "front" else null).joinToString(",")
        val hello = WireProtocol.encodeControl(mapOf(
            "model" to Build.MODEL, "brand" to Build.BRAND,
            "sdk" to Build.VERSION.SDK_INT.toString(),
            "cameras" to cameras, "uvc" to "unknown",
            "codecs" to EncoderCaps.csv(), "configV2" to "1",
            "id" to deviceId(), "gen" to streamGeneration.toString()))
        hub.sendHello(hello)
    }

    /** Camera/encoder error state for the dashboard; streaming may still need stopping. */
    val hasCameraError: Boolean get() = lastErrorStatus != null

    /** Current summary for an Activity attaching to an already-running service. */
    fun currentStatus(): String = when {
        lastErrorStatus != null -> lastErrorStatus!!
        pendingStart != null -> CameraStartPolicy.OPEN_APP_STATUS
        !streaming -> "Not streaming"
        hub.peerCount() > 0 -> "Streaming to Mac (${hub.peerCount()} connection)"
        else -> "Streaming — waiting for Mac on USB"
    }

    private fun emitStatus(note: String? = null) {
        statusListener?.invoke(note ?: currentStatus())
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
        runCatching { displayManager?.unregisterDisplayListener(displayListener) }
        stopStreaming()
        wifiAdvertiser?.stop()
        wifiAdvertiser = null
        adbTransport.close()
        aoaTransport.close()
        hub.closeAll()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "streaming"
        private const val ID = 1
        private const val ROTATION_DEBOUNCE_MS = 500L
        private const val PREF_CAMERA_ID = "selected_camera_id"
        private const val PREF_ENHANCE = "enhance_enabled"
        private const val PREF_QUALITY = "stream_quality"
        private const val PREF_DEVICE_ID = "device_id"
        private const val PREF_WIFI_DISCOVERY = "wifi_discovery"
    }
}
