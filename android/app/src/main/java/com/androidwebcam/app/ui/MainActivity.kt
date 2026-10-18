package com.androidwebcam.app.ui

import android.Manifest
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
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.view.View
import android.widget.AdapterView
import com.androidwebcam.app.R
import com.androidwebcam.app.camera.CameraInfo
import com.androidwebcam.app.camera.CameraStreamingService
import com.androidwebcam.app.util.UsbConfigHelper

class MainActivity : Activity() {

    private var service: CameraStreamingService? = null
    private var previewSurface: Surface? = null
    private lateinit var mainLayout: LinearLayout
    private lateinit var previewContainer: FrameLayout
    private lateinit var controlsContainer: ScrollView
    private lateinit var status: TextView
    private lateinit var toggle: Button
    // Nullable so a layout missing this view degrades instead of crashing on startup.
    private var cameraSelector: Spinner? = null
    private var enhanceToggle: Switch? = null
    private lateinit var previewView: SquareTextureView
    private lateinit var orientationLabel: TextView
    private var quarterTurns = 0
    private var cameraList: List<CameraInfo> = emptyList()

    private val connection = object : ServiceConnection {
        override fun onServiceDisconnected(name: ComponentName?) { service = null }
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val svc = (binder as? CameraStreamingService.LocalBinder)?.service() ?: return
            service = svc
            svc.setPreviewSurface(previewSurface)
            svc.statusListener = { text -> runOnUiThread { status.text = text } }
            svc.rotationListener = { turns ->
                runOnUiThread { applyRotation(turns) }
            }
            svc.cameraChangeListener = { activeId ->
                runOnUiThread { updateCameraSelection(activeId) }
            }
            status.text = svc.uvcGuidance()
            applyRotation(svc.rotationQuarterTurns)
            enhanceToggle?.isChecked = svc.enhancementEnabled
            updateCameraList(svc)
            if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
                svc.connectAccessory()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        mainLayout = findViewById(R.id.mainLayout)
        previewContainer = findViewById(R.id.previewContainer)
        controlsContainer = findViewById(R.id.controlsContainer)
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
        resolution.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_dropdown_item,
            listOf("Best quality · auto", "1920 × 1080 · 30 FPS", "1280 × 720 · 30 FPS"))

        enhanceToggle = findViewById(R.id.enhanceToggle)
        enhanceToggle?.setOnCheckedChangeListener { _, isChecked ->
            service?.setEnhancementEnabled(isChecked)
        }

        updateLayoutForOrientation(resources.configuration.orientation)

        previewView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(s: SurfaceTexture, w: Int, h: Int) {
                    previewSurface = Surface(s)
                    service?.setPreviewSurface(previewSurface)
                    applyRotation(quarterTurns)
                }
                override fun onSurfaceTextureDestroyed(s: SurfaceTexture): Boolean {
                    service?.setPreviewSurface(null)
                    previewSurface?.release(); previewSurface = null
                    return true
                }
                override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, w: Int, h: Int) {
                    applyRotation(quarterTurns)
                }
                override fun onSurfaceTextureUpdated(s: SurfaceTexture) = Unit
            }

        toggle.setOnClickListener {
            val svc = service ?: return@setOnClickListener
            if (svc.streaming) {
                svc.stopStreaming()
                toggle.text = getString(R.string.start_streaming)
            } else if (hasCameraPermission()) {
                val (w, h, q) = when (resolution.selectedItemPosition) {
                    2 -> Triple(1280, 720, com.androidwebcam.app.camera.StreamQuality.BALANCED)
                    1 -> Triple(1920, 1080, com.androidwebcam.app.camera.StreamQuality.HIGH)
                    else -> Triple(1920, 1080, com.androidwebcam.app.camera.StreamQuality.BEST)
                }
                svc.startStreaming(w, h, 30, q)
                toggle.text = getString(R.string.stop_streaming)
            } else {
                requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
            }
        }
        findViewById<Button>(R.id.switchCamera).setOnClickListener { service?.switchCamera() }
        findViewById<Button>(R.id.rotate).setOnClickListener { service?.rotate() }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }

        setupUsbConfigCard()

        bindService(Intent(this, CameraStreamingService::class.java), connection, BIND_AUTO_CREATE)
    }

    /** Rotates the square preview; the same turns go to the Mac via CONFIG. */
    private fun applyRotation(turns: Int) {
        quarterTurns = turns and 3
        if (::previewView.isInitialized && previewView.width > 0) {
            val matrix = Matrix()
            matrix.postRotate(
                (quarterTurns * 90).toFloat(),
                previewView.width / 2f, previewView.height / 2f)
            previewView.setTransform(matrix)
        }
        if (::orientationLabel.isInitialized) {
            orientationLabel.text = "Orientation: ${quarterTurns * 90}°"
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateLayoutForOrientation(newConfig.orientation)
    }

    private fun updateLayoutForOrientation(orientation: Int) {
        val isLandscape = orientation == Configuration.ORIENTATION_LANDSCAPE
        if (::mainLayout.isInitialized && ::previewContainer.isInitialized && ::controlsContainer.isInitialized) {
            if (isLandscape) {
                mainLayout.orientation = LinearLayout.HORIZONTAL
                previewContainer.layoutParams = LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
                controlsContainer.layoutParams = LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
            } else {
                mainLayout.orientation = LinearLayout.VERTICAL
                previewContainer.layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
                controlsContainer.layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            }
            if (::previewView.isInitialized) {
                previewView.post { applyRotation(quarterTurns) }
            }
        }
    }

    private fun updateCameraList(svc: CameraStreamingService) {
        val cameras = svc.getAvailableCameras()
        cameraList = cameras
        val adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_dropdown_item,
            cameras.map { it.displayName })
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
        }
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
        if (UsbConfigHelper.tryConfigureViaRoot()) {
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
                    startActivity(UsbConfigHelper.createDeveloperOptionsIntent())
                } catch (_: ActivityNotFoundException) {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                }
            } else {
                Toast.makeText(this, R.string.usb_enable_dev_options_hint, Toast.LENGTH_LONG).show()
                try {
                    startActivity(UsbConfigHelper.createAboutPhoneIntent())
                } catch (_: ActivityNotFoundException) {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                }
            }
        }

        btnDismissUsbSetup.setOnClickListener {
            UsbConfigHelper.setSetupDismissed(this, true)
            usbSetupCard.visibility = View.GONE
        }
    }

    override fun onDestroy() {
        runCatching { unbindService(connection) }
        super.onDestroy()
    }

    companion object {
        private const val REQ_CAMERA = 1
        private const val REQ_NOTIFY = 2
    }
}
