package com.androidwebcam.app.transport

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Phase 3 transport: Android Open Accessory bulk streams, no USB debugging.
 * The Mac host must first switch the phone into accessory mode (see
 * docs/ACCESSORY.md); Android then delivers USB_ACCESSORY_ATTACHED.
 */
class UsbAccessoryTransport(
    context: Context,
    private val hub: TransportHub,
) : Transport {
    override val name = "aoa-usb"
    private val manager = context.getSystemService(UsbManager::class.java)
    private var descriptor: ParcelFileDescriptor? = null

    fun attachedAccessory(): UsbAccessory? = manager.accessoryList?.firstOrNull()

    fun permissionIntentAction(): String = "com.androidwebcam.app.USB_PERMISSION"

    /** Call after permission is granted for [accessory]. */
    fun open(accessory: UsbAccessory, onControl: (Map<String, String>) -> Unit): Boolean {
        val fd = manager.openAccessory(accessory) ?: return false
        descriptor = fd
        hub.attach(FileInputStream(fd.fileDescriptor), FileOutputStream(fd.fileDescriptor), onControl)
        return true
    }

    override fun start(onControl: (Map<String, String>) -> Unit) {
        attachedAccessory()?.let { accessory ->
            if (manager.hasPermission(accessory)) open(accessory, onControl)
        }
    }

    override fun close() {
        runCatching { descriptor?.close() }
        descriptor = null
    }
}
