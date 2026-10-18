package com.androidwebcam.app

import com.androidwebcam.app.transport.NativeUvcSupport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeUvcSupportTest {

    @Test
    fun android14GuidanceNamesWebcamOptionAndStreamingFallback() {
        val text = NativeUvcSupport.guidance(34)
        assertTrue(text.contains("Webcam"))
        assertTrue(text.contains("Start Streaming"))
    }

    @Test
    fun android14GuidanceSaysAppCannotEnableUvcMode() {
        val text = NativeUvcSupport.guidance(34)
        assertTrue(text.contains("cannot turn that mode on"))
        assertTrue(text.contains("firmware"))
    }

    @Test
    fun android14GuidanceSaysAppControlsDoNotApplyInSystemMode() {
        val text = NativeUvcSupport.guidance(34)
        assertTrue(text.contains("controls do not apply"))
    }

    @Test
    fun preAndroid14GuidanceRequiresAndroid14AndKeepsStreaming() {
        val text = NativeUvcSupport.guidance(33)
        assertTrue(text.contains("Android 14+"))
        assertTrue(text.contains("Start Streaming"))
    }

    @Test
    fun noArgGuidanceDelegatesToDeviceSdk() {
        assertEquals(NativeUvcSupport.guidance(0), NativeUvcSupport.guidance())
    }
}
