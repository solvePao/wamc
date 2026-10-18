package com.androidwebcam.app

import com.androidwebcam.app.camera.EncoderLifecycle
import com.androidwebcam.app.camera.EncoderRuntime
import com.androidwebcam.app.camera.QualitySelector
import com.androidwebcam.app.camera.StreamQuality
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EncoderLifecycleTest {
    private val profile = QualitySelector.profileFor(
        StreamQuality.BEST, QualitySelector.AVC, 640, 480, 30,
    )

    @Test fun startErrorsPropagateToPipelineOwner() {
        val runtime = FakeRuntime().apply { startFailure = IllegalStateException("codec unavailable") }
        val lifecycle = EncoderLifecycle(runtime, profile)
        assertThrows(IllegalStateException::class.java) { lifecycle.start() }
        assertEquals(listOf("start"), runtime.calls)
    }

    @Test fun cleanupContinuesWhenIndividualCodecOperationsFail() {
        val runtime = FakeRuntime().apply {
            stopFailure = IllegalStateException("not started")
            releaseFailure = IllegalStateException("release failed")
            surfaceFailure = IllegalStateException("surface released")
            keyframeFailure = IllegalStateException("keyframe unsupported")
        }
        val lifecycle = EncoderLifecycle(runtime, profile)
        lifecycle.requestKeyframe()
        lifecycle.stop()
        assertEquals(listOf("keyframe", "stop", "release", "surface"), runtime.calls)
    }

    @Test fun successfulStartAndStopCallRuntimeInOrder() {
        val runtime = FakeRuntime()
        val lifecycle = EncoderLifecycle(runtime, profile)
        lifecycle.start()
        lifecycle.stop()
        assertEquals(listOf("start", "stop", "release", "surface"), runtime.calls)
    }

    private class FakeRuntime : EncoderRuntime {
        val calls = mutableListOf<String>()
        var startFailure: RuntimeException? = null
        var stopFailure: RuntimeException? = null
        var releaseFailure: RuntimeException? = null
        var surfaceFailure: RuntimeException? = null
        var keyframeFailure: RuntimeException? = null
        override fun start() { calls += "start"; startFailure?.let { throw it } }
        override fun requestKeyframe() { calls += "keyframe"; keyframeFailure?.let { throw it } }
        override fun stop() { calls += "stop"; stopFailure?.let { throw it } }
        override fun release() { calls += "release"; releaseFailure?.let { throw it } }
        override fun releaseInputSurface() { calls += "surface"; surfaceFailure?.let { throw it } }
    }
}
