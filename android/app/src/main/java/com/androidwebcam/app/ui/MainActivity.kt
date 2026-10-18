package com.androidwebcam.app.ui

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.widget.Toast
import android.view.Surface
import android.view.TextureView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.graphics.Color
import android.widget.AdapterView
import com.androidwebcam.app.R
import com.androidwebcam.app.camera.CameraInfo
import com.androidwebcam.app.camera.PreviewOrientation
import com.androidwebcam.app.camera.CameraStreamingService
import com.androidwebcam.app.util.UsbConfigHelper

class MainActivity : Activity() {

    internal var configureUsb: () -> Boolean = UsbConfigHelper::tryConfigureViaRoot
    internal var launchUsbSettings: (Intent) -> Unit = { startActivity(it) }
    internal var updateCoordinator: () -> com.androidwebcam.app.update.UpdateCoordinator = {
        com.androidwebcam.app.update.AndroidUpdates.get(this)
    }

    private lateinit var updates: com.androidwebcam.app.update.UpdatePresenter
    private var service: CameraStreamingService? = null
    private var previewSurface: Surface? = null
    private lateinit var stateBadge: TextView
    private lateinit var previewPlaceholder: View
    private var updatingControls = false
    private var startAfterPermission = false
    private lateinit var status: TextView
    private lateinit var toggle: Button
    // Nullable so a layout missing this view degrades instead of crashing on startup.
    private var cameraSelector: Spinner? = null
    private var enhanceToggle: Switch? = null
    private var autoStartToggle: Switch? = null
    private var wifiDiscoveryToggle: Switch? = null
    private val prefs by lazy { getSharedPreferences("wamc_prefs", MODE_PRIVATE) }
    private lateinit var previewView: SquareTextureView
    private lateinit var orientationLabel: TextView
    private var previewOrientation = PreviewOrientation()
    private var cameraList: List<CameraInfo> = emptyList()

    private val connection = object : ServiceConnection {
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            renderState()
        }
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val svc = (binder as? CameraStreamingService.LocalBinder)?.service() ?: return
            service = svc
            svc.setPreviewSurface(previewSurface)
            svc.statusListener = { text -> runOnUiThread { renderState(text) } }
            svc.wifiDiscoveryChangeListener = { enabled ->
                runOnUiThread {
                    updatingControls = true
                    wifiDiscoveryToggle?.isChecked = enabled
                    updatingControls = false
                }
            }
            svc.rotationListener = { turns ->
                runOnUiThread { applyRotation(turns) }
            }
            svc.cameraChangeListener = { activeId ->
                runOnUiThread { updateCameraSelection(activeId) }
            }
            svc.setActivityVisible(hasWindowFocus() && lifecycleStarted)
            applyRotation(svc.previewOrientation())
            updatingControls = true
            enhanceToggle?.isChecked = svc.enhancementEnabled
            wifiDiscoveryToggle?.isChecked = svc.wifiDiscoveryEnabled
            updatingControls = false
            updateCameraList(svc)
            maybeAutoStart()
            renderState(svc.currentStatus())
            if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
                svc.connectAccessory()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        updates = com.androidwebcam.app.update.UpdatePresenter(this, updateCoordinator())
        startAfterPermission = savedInstanceState?.getBoolean(STATE_PERMISSION_START) ?: false
        setContentView(R.layout.activity_main)
        stateBadge = findViewById(R.id.stateBadge)
        previewPlaceholder = findViewById(R.id.previewPlaceholder)
        applySystemInsets()
        status = findViewById(R.id.status)
        toggle = findViewById(R.id.toggle)
        orientationLabel = findViewById(R.id.orientationLabel)
        previewView = findViewById(R.id.preview)
        cameraSelector = findViewById(R.id.cameraSelector)
        cameraSelector?.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val selectedCam = cameraList.getOrNull(position) ?: return
                val svc = service ?: return
                if (selectedCam.id != svc.currentCameraId) {
                    svc.selectCamera(selectedCam.id)
                }
            }
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }

        val resolution: Spinner = findViewById(R.id.resolution)
        resolution.adapter = dropdownAdapter(listOf(
            getString(R.string.dashboard_quality_best),
            getString(R.string.dashboard_quality_high),
            getString(R.string.dashboard_quality_balanced)))
        resolution.setSelection(savedInstanceState?.getInt(STATE_QUALITY) ?: 0)

        enhanceToggle = findViewById(R.id.enhanceToggle)
        enhanceToggle?.setOnCheckedChangeListener { _, isChecked ->
            if (!updatingControls) service?.setEnhancementEnabled(isChecked)
        }

        autoStartToggle = findViewById(R.id.autoStartToggle)
        autoStartToggle?.isChecked = prefs.getBoolean(PREF_AUTOSTART, true)
        autoStartToggle?.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean(PREF_AUTOSTART, isChecked).apply()
            if (isChecked) maybeAutoStart()
        }

        wifiDiscoveryToggle = findViewById(R.id.wifiDiscoveryToggle)
        wifiDiscoveryToggle?.isChecked = prefs.getBoolean(PREF_WIFI_DISCOVERY, true)
        wifiDiscoveryToggle?.setOnCheckedChangeListener { _, isChecked ->
            // Service owns the advertiser; it persists the same pref key.
            if (!updatingControls) {
                val svc = service
                if (svc != null) svc.setWifiDiscoveryEnabled(isChecked)
                else prefs.edit().putBoolean(PREF_WIFI_DISCOVERY, isChecked).apply()
            }
        }

        renderState()

        previewView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(s: SurfaceTexture, w: Int, h: Int) {
                    previewSurface = Surface(s)
                    service?.setPreviewSurface(previewSurface)
                    applyRotation(previewOrientation)
                }
                override fun onSurfaceTextureDestroyed(s: SurfaceTexture): Boolean {
                    service?.setPreviewSurface(null)
                    previewSurface?.release(); previewSurface = null
                    return true
                }
                override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, w: Int, h: Int) {
                    applyRotation(previewOrientation)
                }
                override fun onSurfaceTextureUpdated(s: SurfaceTexture) = Unit
            }

        toggle.setOnClickListener {
            val svc = service ?: return@setOnClickListener
            if (svc.streaming) {
                svc.stopStreaming()
                renderState(svc.currentStatus())
            } else if (hasCameraPermission()) {
                startStreamingFromUi()
            } else {
                startAfterPermission = true
                requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
            }
        }
        findViewById<Button>(R.id.switchCamera).setOnClickListener { service?.switchCamera() }
        findViewById<Button>(R.id.rotate).setOnClickListener { service?.rotate() }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }

        findViewById<View>(R.id.updateMenu)?.setOnClickListener { anchor ->
            android.widget.PopupMenu(this, anchor).apply {
                menu.add("Check for Updates…").setOnMenuItemClickListener {
                    updateCoordinator().check(manual = true)
                    true
                }
                show()
            }
        }
        setupUsbConfigCard()

        // Started (not only bound) so the listener survives the activity and
        // the service restarts sticky; streaming itself still needs a trigger.
        startForegroundService(Intent(this, CameraStreamingService::class.java))
        bindService(Intent(this, CameraStreamingService::class.java), connection, BIND_AUTO_CREATE)
    }

    private fun autoStartEnabled(): Boolean =
        prefs.getBoolean(PREF_AUTOSTART, true)

    /** Shared tap path: starts with the spinner's quality, flips the button. */
    private fun startStreamingFromUi() {
        val svc = service ?: return
        if (svc.streaming || !hasCameraPermission() || updateCoordinator().installationInProgress) return
        val spinner: Spinner? = findViewById(R.id.resolution)
        val (w, h, q) = when (spinner?.selectedItemPosition) {
            2 -> Triple(1280, 720, com.androidwebcam.app.camera.StreamQuality.BALANCED)
            1 -> Triple(1920, 1080, com.androidwebcam.app.camera.StreamQuality.HIGH)
            else -> Triple(1920, 1080, com.androidwebcam.app.camera.StreamQuality.BEST)
        }
        svc.startStreaming(w, h, 30, q)
        renderState(svc.currentStatus())
    }

    /** No-tap start on open / after grant / when re-enabled. */
    private fun maybeAutoStart() {
        val updater = updateCoordinator()
        if (!updater.installationInProgress && updater.state !is com.androidwebcam.app.update.UpdateState.Ready &&
            autoStartEnabled() && hasCameraPermission()) startStreamingFromUi()
    }

    override fun onResume() {
        super.onResume()
        lifecycleStarted = true
        service?.setActivityVisible(true)
        // Bind is sticky: resume without re-bind would otherwise sit idle.
        service?.startPendingRequest()
        maybeAutoStart()
        renderState(service?.currentStatus())
        updates.resume()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && lifecycleStarted) {
            service?.let { svc ->
                // Binding may finish before the first focused window. Retry only
                // an existing request, so dismissing a menu never starts a stopped stream.
                svc.setActivityVisible(true)
                svc.startPendingRequest()
                renderState(svc.currentStatus())
            }
        }
    }

    override fun onPause() {
        updates.pause()
        lifecycleStarted = false
        service?.setActivityVisible(false)
        super.onPause()
    }

    /** Render from service state so remote starts/stops and rebinds match the controls. */
    private fun renderState(message: String? = null) {
        if (!::toggle.isInitialized) return
        val svc = service
        val streaming = svc?.streaming == true
        if (::updates.isInitialized) updates.streamingChanged(svc == null || streaming)
        status.text = message ?: svc?.currentStatus() ?: getString(R.string.dashboard_connecting)
        stateBadge.setText(when {
            svc == null -> R.string.dashboard_connecting
            svc.hasCameraError -> R.string.dashboard_camera_error
            streaming -> R.string.dashboard_camera_on
            else -> R.string.dashboard_ready
        })
        val cameraError = svc?.hasCameraError == true
        stateBadge.setBackgroundResource(if (cameraError) R.drawable.bg_btn_stop else R.drawable.bg_badge)
        stateBadge.setTextColor(getColor(if (cameraError) R.color.dashboard_stop_text else R.color.dashboard_accent))
        toggle.setText(if (streaming) R.string.stop_streaming else R.string.start_streaming)
        toggle.setBackgroundResource(if (streaming) R.drawable.bg_btn_stop else R.drawable.bg_btn_primary)
        val actionColor = getColor(if (streaming) R.color.dashboard_stop_text else R.color.dashboard_accent_text)
        toggle.setTextColor(actionColor)
        toggle.setCompoundDrawablesRelativeWithIntrinsicBounds(
            if (streaming) R.drawable.ic_stop else R.drawable.ic_play, 0, 0, 0)
        toggle.compoundDrawableTintList = android.content.res.ColorStateList.valueOf(actionColor)
        toggle.isEnabled = svc != null
        toggle.alpha = if (svc != null) 1f else 0.5f
        // Keep the TextureView attached: visibility changes recreate its surface
        // and can race the camera open started by the permission/Start path.
        previewPlaceholder.visibility = if (streaming) View.GONE else View.VISIBLE
        val ready = svc != null && hasCameraPermission()
        listOf<View?>(cameraSelector, enhanceToggle, findViewById(R.id.switchCamera), findViewById(R.id.rotate))
            .forEach { view ->
                view?.isEnabled = ready
                view?.alpha = if (ready) 1f else 0.45f
            }
        if (!hasCameraPermission() && svc != null) {
            status.setText(R.string.dashboard_permission_status)
        }
        status.contentDescription = status.text
        status.tooltipText = status.text
        updatingControls = true
        svc?.let {
            enhanceToggle?.isChecked = it.enhancementEnabled
            wifiDiscoveryToggle?.isChecked = it.wifiDiscoveryEnabled
        }
        updatingControls = false
    }

    private fun dropdownAdapter(items: List<String>) = ArrayAdapter(
        this, R.layout.spinner_item, items).apply {
        setDropDownViewResource(R.layout.spinner_dropdown_item)
    }

    @Suppress("DEPRECATION") // The legacy path supports Android 8–10.
    @SuppressLint("NewApi") // DisplayCutout APIs are guarded for API 28+ below.
    private fun applySystemInsets() {
        val root: View = findViewById(R.id.mainLayout)
        val horizontal = resources.getDimensionPixelSize(R.dimen.dashboard_padding)
        val vertical = resources.getDimensionPixelSize(R.dimen.dashboard_spacing)
        // One inset owner across Android 8–15; avoid double padding on older releases.
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.setSystemBarsAppearance(0,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
        if (Build.VERSION.SDK_INT < 35) {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }
        root.setOnApplyWindowInsetsListener { view, insets ->
            val left: Int
            val top: Int
            val right: Int
            val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                left = bars.left; top = bars.top; right = bars.right; bottom = bars.bottom
            } else {
                val cutout = if (Build.VERSION.SDK_INT >= 28) insets.displayCutout else null
                left = maxOf(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0)
                top = maxOf(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0)
                right = maxOf(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0)
                bottom = maxOf(insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0)
            }
            view.setPadding(horizontal + left, vertical + top, horizontal + right, vertical + bottom)
            insets
        }
        root.requestApplyInsets()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PERMISSION_START, startAfterPermission)
        outState.putInt(STATE_QUALITY, findViewById<Spinner>(R.id.resolution).selectedItemPosition)
        super.onSaveInstanceState(outState)
    }

    /** Apply only the residual TextureView transform; labels describe stream orientation. */
    private fun applyRotation(orientation: PreviewOrientation) {
        previewOrientation = orientation
        if (::previewView.isInitialized && previewView.width > 0) {
            val matrix = Matrix()
            matrix.postRotate(
                (orientation.transformTurns * 90).toFloat(),
                previewView.width / 2f, previewView.height / 2f)
            previewView.setTransform(matrix)
        }
        if (::orientationLabel.isInitialized) {
            orientationLabel.text = getString(R.string.dashboard_orientation, orientation.labelTurns * 90)
            orientationLabel.contentDescription = getString(R.string.dashboard_orientation_description, orientation.labelTurns * 90)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        findViewById<View>(R.id.dashboard).requestLayout()
        previewView.post { applyRotation(previewOrientation) }
        // Display rotation may have changed the compensated total: let the
        // service resend CONFIG (or restart for a HAL mode change).
        service?.notifyConfigurationChanged()
    }

    private fun updateCameraList(svc: CameraStreamingService) {
        val cameras = svc.getAvailableCameras()
        cameraList = cameras
        val adapter = dropdownAdapter(cameras.map { it.displayName })
        cameraSelector?.adapter = adapter
        updateCameraSelection(svc.currentCameraId)
    }

    private fun updateCameraSelection(activeId: String) {
        val selector = cameraSelector ?: return
        val idx = cameraList.indexOfFirst { it.id == activeId }
        if (idx >= 0 && selector.selectedItemPosition != idx) {
            selector.setSelection(idx)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            service?.let { updateCameraList(it) }
            if (startAfterPermission) startStreamingFromUi() else maybeAutoStart()
        }
        if (requestCode == REQ_CAMERA) startAfterPermission = false
        renderState(service?.currentStatus())
    }

    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun setupUsbConfigCard() {
        val usbSetupCard: View? = findViewById(R.id.usbSetupCard)
        val btnConfigureUsb: Button? = findViewById(R.id.btnConfigureUsb)
        val btnDismissUsbSetup: Button? = findViewById(R.id.btnDismissUsbSetup)
        if (usbSetupCard == null || btnConfigureUsb == null || btnDismissUsbSetup == null) return

        if (UsbConfigHelper.isSetupDismissed(this)) {
            usbSetupCard.visibility = View.GONE
            return
        }

        // If device is rooted, attempt silent configuration and dismiss
        if (configureUsb()) {
            UsbConfigHelper.setSetupDismissed(this, true)
            Toast.makeText(this, R.string.usb_setup_configured_root, Toast.LENGTH_LONG).show()
            usbSetupCard.visibility = View.GONE
            return
        }

        usbSetupCard.visibility = View.VISIBLE

        btnConfigureUsb.setOnClickListener {
            if (UsbConfigHelper.isDeveloperOptionsEnabled(this)) {
                Toast.makeText(this, R.string.usb_dev_options_hint, Toast.LENGTH_LONG).show()
                try {
                    launchUsbSettings(UsbConfigHelper.createDeveloperOptionsIntent())
                } catch (_: ActivityNotFoundException) {
                    launchUsbSettings(Intent(Settings.ACTION_SETTINGS))
                }
            } else {
                Toast.makeText(this, R.string.usb_enable_dev_options_hint, Toast.LENGTH_LONG).show()
                try {
                    launchUsbSettings(UsbConfigHelper.createAboutPhoneIntent())
                } catch (_: ActivityNotFoundException) {
                    launchUsbSettings(Intent(Settings.ACTION_SETTINGS))
                }
            }
        }

        btnDismissUsbSetup.setOnClickListener {
            UsbConfigHelper.setSetupDismissed(this, true)
            usbSetupCard.visibility = View.GONE
        }
    }

    override fun onDestroy() {
        service?.let {
            it.statusListener = null
            it.rotationListener = null
            it.cameraChangeListener = null
            it.wifiDiscoveryChangeListener = null
        }
        runCatching { unbindService(connection) }
        super.onDestroy()
    }

    companion object {
        private const val STATE_PERMISSION_START = "start_after_permission"
        private const val STATE_QUALITY = "selected_quality"
        private const val REQ_CAMERA = 1
        private const val REQ_NOTIFY = 2
        private const val PREF_AUTOSTART = "auto_start"
        private const val PREF_WIFI_DISCOVERY = "wifi_discovery"
    }

    @Volatile private var lifecycleStarted = false
}
