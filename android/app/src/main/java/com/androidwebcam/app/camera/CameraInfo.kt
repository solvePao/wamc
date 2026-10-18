package com.androidwebcam.app.camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import kotlin.math.sqrt

/**
 * Front-first default pick: webcam use favors the front camera. An explicit
 * saved choice always wins; otherwise front, then main back, then anything.
 * Pure data in/out, covered by unit tests.
 */
object DefaultCamera {
    fun pickId(cameras: List<CameraInfo>, savedId: String?): String? {
        if (savedId != null && cameras.any { it.id == savedId }) return savedId
        cameras.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_FRONT }?.let {
            return it.id
        }
        cameras.firstOrNull {
            it.facing == CameraCharacteristics.LENS_FACING_BACK && it.lensType == LensType.MAIN
        }?.let { return it.id }
        return cameras.firstOrNull()?.id
    }
}

enum class LensType {
    MAIN,
    ULTRA_WIDE,
    TELEPHOTO,
    FRONT,
    EXTERNAL,
    OTHER
}

data class CameraInfo(
    val id: String,
    val facing: Int,
    val lensType: LensType,
    val displayName: String
)

object CameraClassifier {
    // 35mm film frame diagonal (36mm x 24mm) is ~43.27 mm
    private const val DIAGONAL_35MM = 43.266615f

    data class RawCameraProps(
        val id: String,
        val facing: Int,
        val focalLength: Float?,
        val sensorWidth: Float? = null,
        val sensorHeight: Float? = null,
        val eq35mm: Float? = null
    )

    fun calculateEquivalent35mm(focalLength: Float?, sensorWidth: Float?, sensorHeight: Float?): Float? {
        if (focalLength == null || focalLength <= 0f ||
            sensorWidth == null || sensorWidth <= 0f ||
            sensorHeight == null || sensorHeight <= 0f) {
            return null
        }
        val sensorDiagonal = sqrt(sensorWidth * sensorWidth + sensorHeight * sensorHeight)
        if (sensorDiagonal <= 0f) return null
        val cropFactor = DIAGONAL_35MM / sensorDiagonal
        return focalLength * cropFactor
    }

    fun enumerateCameras(manager: CameraManager): List<CameraInfo> {
        val ids = manager.cameraIdList
        val rawProps = ids.mapNotNull { id ->
            runCatching {
                val chars = manager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING) ?: CameraCharacteristics.LENS_FACING_BACK
                val focalLength = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
                val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                val sensorW = sensorSize?.width
                val sensorH = sensorSize?.height
                val eq35 = calculateEquivalent35mm(focalLength, sensorW, sensorH)
                RawCameraProps(id, facing, focalLength, sensorW, sensorH, eq35)
            }.getOrNull()
        }
        return classifyRawCameras(rawProps)
    }

    fun classifyRawCameras(cameras: List<RawCameraProps>): List<CameraInfo> {
        val backCameras = cameras.filter { it.facing == CameraCharacteristics.LENS_FACING_BACK }
        val frontCameras = cameras.filter { it.facing == CameraCharacteristics.LENS_FACING_FRONT }
        val externalCameras = cameras.filter { it.facing == CameraCharacteristics.LENS_FACING_EXTERNAL }

        val classifiedBack = classifyBackCameras(backCameras)
        val classifiedFront = classifyFrontCameras(frontCameras)
        val classifiedExternal = externalCameras.mapIndexed { idx, cam ->
            val label = if (externalCameras.size == 1) "External Camera" else "External Camera ${idx + 1}"
            CameraInfo(cam.id, cam.facing, LensType.EXTERNAL, label)
        }

        return classifiedBack + classifiedFront + classifiedExternal
    }

    private fun classifyBackCameras(backCameras: List<RawCameraProps>): List<CameraInfo> {
        if (backCameras.isEmpty()) return emptyList()
        if (backCameras.size == 1) {
            return listOf(CameraInfo(backCameras[0].id, backCameras[0].facing, LensType.MAIN, "Back Camera"))
        }

        val classified = backCameras.mapIndexed { index, cam ->
            val type = when {
                cam.eq35mm != null -> {
                    when {
                        cam.eq35mm < 23f -> LensType.ULTRA_WIDE
                        cam.eq35mm > 45f -> LensType.TELEPHOTO
                        else -> LensType.MAIN
                    }
                }
                cam.focalLength != null -> {
                    val minFocal = backCameras.mapNotNull { it.focalLength }.minOrNull()
                    val maxFocal = backCameras.mapNotNull { it.focalLength }.maxOrNull()
                    when {
                        cam.focalLength == minFocal && (maxFocal != null && maxFocal > minFocal * 1.5f) -> LensType.ULTRA_WIDE
                        cam.focalLength == maxFocal && (minFocal != null && maxFocal > minFocal * 1.5f) -> LensType.TELEPHOTO
                        else -> LensType.MAIN
                    }
                }
                else -> {
                    if (index == 0 || cam.id == "0") LensType.MAIN else LensType.OTHER
                }
            }
            cam to type
        }

        val hasMain = classified.any { it.second == LensType.MAIN }
        val finalClassified = if (!hasMain) {
            classified.mapIndexed { i, pair ->
                if (i == 0 || pair.first.id == "0") pair.first to LensType.MAIN else pair
            }
        } else {
            classified
        }

        val typeCounts = finalClassified.groupingBy { it.second }.eachCount()

        return finalClassified.map { (cam, type) ->
            val baseName = when (type) {
                LensType.MAIN -> "Back Camera (Main)"
                LensType.ULTRA_WIDE -> "Back Camera (Ultra Wide)"
                LensType.TELEPHOTO -> "Back Camera (Telephoto)"
                else -> "Back Camera (${cam.id})"
            }
            val displayName = if ((typeCounts[type] ?: 0) > 1 && type != LensType.OTHER) {
                "$baseName [${cam.id}]"
            } else {
                baseName
            }
            CameraInfo(cam.id, cam.facing, type, displayName)
        }
    }

    private fun classifyFrontCameras(frontCameras: List<RawCameraProps>): List<CameraInfo> {
        if (frontCameras.isEmpty()) return emptyList()
        if (frontCameras.size == 1) {
            return listOf(CameraInfo(frontCameras[0].id, frontCameras[0].facing, LensType.FRONT, "Front Camera"))
        }
        return frontCameras.mapIndexed { index, cam ->
            CameraInfo(cam.id, cam.facing, LensType.FRONT, "Front Camera ${index + 1}")
        }
    }
}
