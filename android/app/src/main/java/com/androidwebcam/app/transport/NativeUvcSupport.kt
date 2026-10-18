package com.androidwebcam.app.transport

import android.os.Build

/**
 * Native USB webcam (UVC gadget) detection/guidance.
 * A regular app cannot enable UVC gadget mode; only firmware can. On Android
 * 14+ devices where the maker enabled it, the phone appears on macOS as a
 * webcam with no app at all — the Mac side enumerates it via AVFoundation.
 */
object NativeUvcSupport {
    fun guidance(): String = guidance(Build.VERSION.SDK_INT)

    /**
     * Testable overload: [sdkInt] stands in for [Build.VERSION.SDK_INT].
     * A regular app cannot enable UVC gadget mode; only the phone's firmware
     * can offer the USB 'Webcam' option, so this only guides the user there.
     */
    fun guidance(sdkInt: Int): String = when {
        sdkInt >= 34 ->
            "USB webcam without the Mac app (phone firmware permitting): " +
            "plug the phone into the Mac, open the phone's USB notification " +
            "('Charging this device via USB — tap for more options'), " +
            "and if this phone offers 'Webcam', select it — macOS then lists " +
            "the phone as a camera with no app needed. " +
            "This app cannot turn that mode on; only the firmware can offer it. " +
            "While the system webcam mode owns the camera, this app's " +
            "switch/rotate/resolution controls do not apply. " +
            "If no 'Webcam' option appears, your firmware does not offer it — " +
            "use Start Streaming instead."
        else ->
            "Native USB webcam mode needs Android 14+ firmware support, " +
            "and this app cannot turn it on. " +
            "This app streams over USB instead — use Start Streaming."
    }
}
