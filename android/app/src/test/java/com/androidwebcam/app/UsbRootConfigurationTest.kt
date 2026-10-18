package com.androidwebcam.app

import android.content.ContextWrapper
import android.content.ContentResolver
import com.androidwebcam.app.util.UsbConfigHelper
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class UsbRootConfigurationTest {
    private class RootProcess(private val status: Int) : Process() {
        val commands = ByteArrayOutputStream()
        override fun getOutputStream() = commands
        override fun getInputStream() = ByteArrayInputStream(byteArrayOf())
        override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
        override fun waitFor() = status
        override fun exitValue() = status
        override fun destroy() = Unit
    }

    @Test fun rootConfigurationWritesBothModesAndRequiresSuccessfulExit() {
        for (status in listOf(0, 1)) {
            val process = RootProcess(status)
            assertEquals(status == 0, UsbConfigHelper.tryConfigureViaRoot { process })
            assertEquals("svc usb setScreenUnlockedFunctions mtp\nsvc usb setFunctions mtp\nexit\n",
                process.commands.toString("UTF-8"))
        }
        assertFalse(UsbConfigHelper.tryConfigureViaRoot { throw SecurityException("root unavailable") })
    }

    @Test fun unavailableSettingsProviderFallsBackToDisabledDeveloperOptions() {
        val context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
            override fun getContentResolver(): ContentResolver = throw SecurityException("settings unavailable")
        }
        assertFalse(UsbConfigHelper.isDeveloperOptionsEnabled(context))
    }
}
