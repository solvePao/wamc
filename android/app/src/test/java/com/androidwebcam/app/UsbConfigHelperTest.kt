package com.androidwebcam.app

import com.androidwebcam.app.util.UsbConfigHelper
import org.junit.Assert.assertNotNull
import org.junit.Test

class UsbConfigHelperTest {

    @Test
    fun developerOptionsIntentIsCreated() {
        val intent = UsbConfigHelper.createDeveloperOptionsIntent()
        assertNotNull(intent)
    }

    @Test
    fun aboutPhoneIntentIsCreated() {
        val intent = UsbConfigHelper.createAboutPhoneIntent()
        assertNotNull(intent)
    }
}

