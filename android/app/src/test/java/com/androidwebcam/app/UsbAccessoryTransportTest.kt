package com.androidwebcam.app

import android.hardware.usb.UsbAccessory
import android.os.ParcelFileDescriptor
import com.androidwebcam.app.transport.TransportHub
import com.androidwebcam.app.transport.UsbAccessoryBackend
import com.androidwebcam.app.transport.UsbAccessoryTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class UsbAccessoryTransportTest {
    @Test fun absentAccessoryIsSafeAndTransportCanCloseRepeatedly() {
        val hub = TransportHub()
        val transport = UsbAccessoryTransport(RuntimeEnvironment.getApplication(), hub)
        assertNull(transport.attachedAccessory())
        assertEquals("com.androidwebcam.app.USB_PERMISSION", transport.permissionIntentAction())
        transport.start {}
        transport.close()
        transport.close()
        hub.closeAll()
    }

    @Test fun missingPermissionDoesNotOpenAccessory() {
        val accessory = accessory()
        val backend = FakeBackend(arrayOf(accessory), permission = false)
        val transport = UsbAccessoryTransport(
            RuntimeEnvironment.getApplication(), TransportHub(), backend,
        )
        transport.start {}
        assertEquals(0, backend.openCalls)
        transport.close()
    }

    @Test fun nullDescriptorAndBackendExceptionsReturnFailure() {
        val accessory = accessory()
        val noDescriptor = FakeBackend(arrayOf(accessory), permission = true)
        val transport = UsbAccessoryTransport(
            RuntimeEnvironment.getApplication(), TransportHub(), noDescriptor,
        )
        assertFalse(transport.open(accessory) {})
        transport.close()

        val throwing = FakeBackend(arrayOf(accessory), permission = true).apply {
            openFailure = IllegalStateException("USB unavailable")
        }
        val failingTransport = UsbAccessoryTransport(
            RuntimeEnvironment.getApplication(), TransportHub(), throwing,
        )
        assertFalse(failingTransport.open(accessory) {})
        failingTransport.close()
    }

    @Test fun validAccessoryDescriptorAttachesToTransportHub() {
        val accessory = accessory()
        val descriptors = ParcelFileDescriptor.createPipe()
        val backend = FakeBackend(arrayOf(accessory), permission = true, descriptor = descriptors[0])
        val hub = TransportHub()
        val transport = UsbAccessoryTransport(RuntimeEnvironment.getApplication(), hub, backend)

        assertTrue(transport.open(accessory) {})
        transport.close()
        hub.closeAll()
        descriptors[1].close()
    }

    private fun accessory() = ReflectionHelpers.callConstructor(UsbAccessory::class.java)

    private class FakeBackend(
        private val attached: Array<UsbAccessory>?,
        private val permission: Boolean,
        private val descriptor: ParcelFileDescriptor? = null,
    ) : UsbAccessoryBackend {
        var openCalls = 0
        var openFailure: RuntimeException? = null
        override fun accessories(): Array<UsbAccessory>? = attached
        override fun hasPermission(accessory: UsbAccessory): Boolean = permission
        override fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor? {
            openCalls++
            openFailure?.let { throw it }
            return descriptor
        }
    }
}
