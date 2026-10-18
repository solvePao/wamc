package com.androidwebcam.app.camera

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraStartPolicyTest {
    @Test
    fun remoteStartQueuesWhileActivityIsBackgrounded() {
        assertEquals(
            RemoteStartDecision.QUEUE_FOR_VISIBLE_ACTIVITY,
            CameraStartPolicy.remoteStartDecision(activityVisible = false),
        )
        assertEquals(
            "Open WAMC on the phone to start the camera",
            CameraStartPolicy.OPEN_APP_STATUS,
        )
    }

    @Test
    fun remoteStartCanRunWhileActivityIsVisible() {
        assertEquals(
            RemoteStartDecision.START,
            CameraStartPolicy.remoteStartDecision(activityVisible = true),
        )
    }
}
