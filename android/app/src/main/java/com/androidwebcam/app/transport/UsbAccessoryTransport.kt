package com.androidwebcam.app.transport

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import com.androidwebcam.app.util.AppLog
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Phase 3 transport: Android Open Accessory bulk streams, no USB debugging.
 * The Mac host must first switch the phone into accessory mode (see
 * docs/ACCESSORY.md); Android then delivers USB_ACCESSORY_ATTACHED.
 */
class UsbAccessoryTransport internal constructor(
    context: Context,
    private val hub: TransportHub,
    private val backendOverride: UsbAccessoryBackend? = null,
) : Transport {
    constructor(context: Context, hub: TransportHub) : this(context, hub, null)

    override val name = "aoa-usb"
    private val backend = backendOverride ?: AndroidUsbAccessoryBackend(
        context.getSystemService(UsbManager::class.java))
    private var descriptor: ParcelFileDescriptor? = null

    fun attachedAccessory(): UsbAccessory? = backend.accessories()?.firstOrNull()

    fun permissionIntentAction(): String = "com.androidwebcam.app.USB_PERMISSION"

    /** Call after permission is granted for [accessory]. */
    fun open(accessory: UsbAccessory, onControl: (Map<String, String>) -> Unit): Boolean {
        return try {
            val fd = backend.openAccessory(accessory) ?: run {
                AppLog.warning("UsbAccessoryTransport", "accessory open returned no descriptor")
                return false
            }
            descriptor = fd
            hub.attach(FileInputStream(fd.fileDescriptor), FileOutputStream(fd.fileDescriptor), onControl)
            AppLog.info("UsbAccessoryTransport", "accessory connected")
            true
        } catch (error: Exception) {
            AppLog.error("UsbAccessoryTransport", "failed to open accessory", error)
            close()
            false
        }
    }

    override fun start(onControl: (Map<String, String>) -> Unit) {
        attachedAccessory()?.let { accessory ->
            if (backend.hasPermission(accessory)) open(accessory, onControl)
            else AppLog.warning("UsbAccessoryTransport", "accessory permission is not granted")
        }
    }

    override fun close() {
        runCatching { descriptor?.close() }
            .onFailure { AppLog.warning("UsbAccessoryTransport", "descriptor close failed", it) }
        descriptor = null
    }
}

/** Narrow USB manager boundary for accessory permission and descriptor handling. */
internal interface UsbAccessoryBackend {
    fun accessories(): Array<UsbAccessory>?
    fun hasPermission(accessory: UsbAccessory): Boolean
    fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor?
}

private class AndroidUsbAccessoryBackend(private val manager: UsbManager?) : UsbAccessoryBackend {
    override fun accessories(): Array<UsbAccessory>? = manager?.accessoryList
    override fun hasPermission(accessory: UsbAccessory): Boolean = manager?.hasPermission(accessory) == true
    override fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor? =
        manager?.openAccessory(accessory)
}
