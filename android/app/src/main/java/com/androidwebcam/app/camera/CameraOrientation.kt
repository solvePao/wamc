package com.androidwebcam.app.camera

/**
 * Sensor/display orientation math. Encoder buffers need rotating by
 * [totalTurns] for an upright picture; TextureView already compensates for
 * sensor orientation and uses its own residual transform; the manual Rotate taps add on top. No Android APIs here,
 * so unit tests cover the whole table.
 *
 * Uses the documented Camera orientation rule:
 * back  = (sensor - device + 360) % 360
 * front = (sensor + device) % 360
 * (mirroring is intentionally left out: the stream stays true-to-sensor).
 */
object CameraOrientation {
    /**
     * @param sensorOrientationDeg SENSOR_ORIENTATION (0/90/180/270).
     * @param deviceDegrees display rotation in degrees (0/90/180/270).
     * @param facingFront true for the front camera.
     * @param userTurns manual Rotate taps (0..3, any int tolerated).
     * @return clockwise quarter-turns (0..3) for an upright picture.
     */
    fun totalTurns(
        sensorOrientationDeg: Int,
        deviceDegrees: Int,
        facingFront: Boolean,
        userTurns: Int,
    ): Int {
        val sensor = ((sensorOrientationDeg % 360) + 360) % 360
        val device = ((deviceDegrees % 360) + 360) % 360
        val base = if (facingFront) (sensor + device) % 360
            else (sensor - device + 360) % 360
        return ((base / 90) + (userTurns and 3)) and 3
    }
}
