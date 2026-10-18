package com.androidwebcam.app.transport

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.androidwebcam.app.util.AppLog
import java.io.BufferedInputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

/**
 * Phase 3 transport: Android Open Accessory bulk streams, no USB debugging.
 * The Mac host must first switch the phone into accessory mode (see
 * docs/ACCESSORY.md); Android then delivers USB_ACCESSORY_ATTACHED.
 */
class UsbAccessoryTransport internal constructor(
    context: Context,
    private val hub: TransportHub,
    private val backendOverride: UsbAccessoryBackend?,
) : Transport {
    constructor(context: Context, hub: TransportHub) : this(context, hub, null)

    override val name = "aoa-usb"
    private val appContext = context.applicationContext
    private val backend = backendOverride ?: AndroidUsbAccessoryBackend(
        context.getSystemService(UsbManager::class.java))
    private val handler = Handler(Looper.getMainLooper())
    private var descriptor: ParcelFileDescriptor? = null
    private var connectedAccessory: UsbAccessory? = null
    private var pendingAccessory: UsbAccessory? = null
    private var permissionRequest: PendingIntent? = null
    private var receiverRegistered = false
    private var onControl: ((Map<String, String>) -> Unit)? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            synchronized(this@UsbAccessoryTransport) {
                val control = onControl ?: return
                when (intent.action) {
                    permissionIntentAction() -> {
                        // An immutable PendingIntent keeps the requested accessory in
                        // our own extras. Always check the actual system permission.
                        val accessory = intent.accessory() ?: return
                        if (accessory != pendingAccessory) return
                        clearPermissionRequest()
                        if (backend.accessories()?.contains(accessory) == true &&
                            backend.hasPermission(accessory)) {
                            open(accessory, control)
                        } else {
                            AppLog.warning("UsbAccessoryTransport", "accessory permission denied or accessory disconnected")
                        }
                    }
                    UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> connectAttached(control)
                    UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                        val accessory = intent.accessory() ?: return
                        if (accessory == connectedAccessory) closeDescriptor()
                        if (accessory == pendingAccessory) clearPermissionRequest()
                    }
                }
            }
        }
    }

    fun attachedAccessory(): UsbAccessory? = backend.accessories()?.firstOrNull(::matches)

    private fun matches(accessory: UsbAccessory): Boolean =
        accessory.manufacturer == "WAMC" &&
            accessory.model == "Wired Android Mac Camera" && accessory.version == "1.0"

    @Suppress("DEPRECATION")
    private fun Intent.accessory(): UsbAccessory? = if (Build.VERSION.SDK_INT >= 33) {
        getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
    } else {
        getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
    }

    fun permissionIntentAction(): String = "com.androidwebcam.app.USB_PERMISSION"

    /** Call after permission is granted for [accessory]. */
    @Synchronized
    fun open(accessory: UsbAccessory, onControl: (Map<String, String>) -> Unit): Boolean {
        if (!matches(accessory) || !backend.hasPermission(accessory)) return false
        if (connectedAccessory == accessory && descriptor != null) return true
        closeDescriptor()
        return try {
            val fd = backend.openAccessory(accessory) ?: run {
                AppLog.warning("UsbAccessoryTransport", "accessory open returned no descriptor")
                return false
            }
            descriptor = fd
            connectedAccessory = accessory
            // Accessory reads consume a whole USB transfer: a one-byte read
            // from the AWC1 parser would otherwise discard the rest of it.
            val input = object : FileInputStream(fd.fileDescriptor) {
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int = try {
                    super.read(bytes, offset, length).also {
                        if (it < 0) connectionLost(fd)
                    }
                } catch (error: IOException) {
                    connectionLost(fd)
                    throw error
                }
            }
            val output = object : FileOutputStream(fd.fileDescriptor) {
                override fun write(bytes: ByteArray) = write(bytes, 0, bytes.size)

                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    try {
                        var written = 0
                        while (written < length) {
                            val count = minOf(ACCESSORY_TRANSFER_SIZE, length - written)
                            super.write(bytes, offset + written, count)
                            written += count
                        }
                    } catch (error: IOException) {
                        connectionLost(fd)
                        throw error
                    }
                }
            }
            hub.attach(BufferedInputStream(input, ACCESSORY_TRANSFER_SIZE), output, { fields ->
                synchronized(this@UsbAccessoryTransport) {
                    if (descriptor === fd && this.onControl != null) onControl(fields)
                }
            })
            AppLog.info("UsbAccessoryTransport", "accessory connected")
            true
        } catch (error: Exception) {
            AppLog.error("UsbAccessoryTransport", "failed to open accessory", error)
            closeDescriptor()
            false
        }
    }

    @Synchronized
    override fun start(onControl: (Map<String, String>) -> Unit) {
        this.onControl = onControl
        if (!receiverRegistered) {
            val filter = IntentFilter(permissionIntentAction()).apply {
                addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
                addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                appContext.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }
        connectAttached(onControl)
    }

    private fun connectAttached(control: (Map<String, String>) -> Unit) {
        val accessory = attachedAccessory() ?: return
        if (backend.hasPermission(accessory)) {
            clearPermissionRequest()
            open(accessory, control)
        } else if (accessory != pendingAccessory) {
            closeDescriptor()
            clearPermissionRequest()
            val request = PendingIntent.getBroadcast(
                appContext, 0,
                Intent(permissionIntentAction()).setPackage(appContext.packageName)
                    .putExtra(UsbManager.EXTRA_ACCESSORY, accessory),
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            pendingAccessory = accessory
            permissionRequest = request
            runCatching { backend.requestPermission(accessory, request) }
                .onFailure {
                    clearPermissionRequest()
                    AppLog.warning("UsbAccessoryTransport", "could not request accessory permission", it)
                }
        }
    }

    @Synchronized
    private fun connectionLost(failedDescriptor: ParcelFileDescriptor) {
        if (descriptor !== failedDescriptor) return
        closeDescriptor()
        // The host may release/reclaim an interface without an Android detach
        // broadcast. Reopen after its failed peer has unwound; stale failures
        // cannot close a newer descriptor or restart a stopped transport.
        handler.postDelayed({
            synchronized(this) {
                val control = onControl
                if (descriptor == null && control != null) connectAttached(control)
            }
        }, 500)
    }

    private fun clearPermissionRequest() {
        permissionRequest?.cancel()
        permissionRequest = null
        pendingAccessory = null
    }

    private fun closeDescriptor() {
        runCatching { descriptor?.close() }
            .onFailure { AppLog.warning("UsbAccessoryTransport", "descriptor close failed", it) }
        descriptor = null
        connectedAccessory = null
    }

    @Synchronized
    override fun close() {
        onControl = null
        handler.removeCallbacksAndMessages(null)
        clearPermissionRequest()
        closeDescriptor()
        if (receiverRegistered) {
            appContext.unregisterReceiver(receiver)
            receiverRegistered = false
        }
    }
    private companion object {
        const val ACCESSORY_TRANSFER_SIZE = 16_384
    }
}

/** Narrow USB manager boundary for accessory permission and descriptor handling. */
internal interface UsbAccessoryBackend {
    fun accessories(): Array<UsbAccessory>?
    fun hasPermission(accessory: UsbAccessory): Boolean
    fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor?
    fun requestPermission(accessory: UsbAccessory, intent: PendingIntent) = Unit
}

private class AndroidUsbAccessoryBackend(private val manager: UsbManager?) : UsbAccessoryBackend {
    override fun accessories(): Array<UsbAccessory>? = manager?.accessoryList
    override fun hasPermission(accessory: UsbAccessory): Boolean = manager?.hasPermission(accessory) == true
    override fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor? =
        manager?.openAccessory(accessory)
    override fun requestPermission(accessory: UsbAccessory, intent: PendingIntent) {
        manager?.requestPermission(accessory, intent)
    }
}
