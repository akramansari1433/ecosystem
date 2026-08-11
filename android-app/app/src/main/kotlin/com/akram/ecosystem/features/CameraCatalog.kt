package com.akram.ecosystem.features

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.SizeF
import com.akram.ecosystem.core.CameraDeviceInfo
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Works out which cameras to offer, and the zoom factors that reach each lens.
 *
 * Phones do not expose one camera per lens. A modern phone publishes a *logical*
 * camera owning several physical lenses, switching between them as you zoom, plus
 * extra entries that duplicate a lens it already covers or are merely cropped
 * modes of another camera. Listing raw camera ids therefore invents cameras that
 * do not exist while hiding lenses that do.
 *
 * Everything here comes from what the phone reports — focal lengths, sensor sizes
 * and zoom ranges — so it holds on any device instead of encoding one phone's
 * quirks.
 */
object CameraCatalog {

    fun list(context: Context): List<CameraDeviceInfo> {
        val manager = context.getSystemService(CameraManager::class.java)
        val cameras = manager.cameraIdList.mapNotNull { id ->
            runCatching { Camera(manager, id) }.getOrNull()
        }
        return listOf(false, true).flatMap { front ->
            offerings(cameras.filter { it.front == front }, front)
        }
    }

    /** One entry per genuinely distinct camera, widest lens first. */
    private fun offerings(cameras: List<Camera>, front: Boolean): List<CameraDeviceInfo> {
        // Prefer cameras that own several lenses: they already reach the others by
        // zooming, so a separate entry for those lenses would be a duplicate.
        val kept = mutableListOf<Camera>()
        for (camera in cameras.sortedWith(
            compareByDescending<Camera> { it.lensFocals.size }
                .thenByDescending { it.sensorArea })
        ) {
            val duplicate = kept.any { kept ->
                kept.coversFocal(camera.focal) ||
                    // Same lens on a smaller sensor: a cropped mode of one we have.
                    (sameFocal(kept.focal, camera.focal) &&
                        camera.sensorArea <= kept.sensorArea)
            }
            if (!duplicate) kept += camera
        }

        return kept.sortedBy { it.focal }.mapIndexed { index, camera ->
            CameraDeviceInfo(
                facing = if (front) "front" else "back",
                id = camera.id,
                label = label(index, kept.size, front),
                maxZoom = camera.maxZoom,
                minZoom = camera.minZoom,
                zoomPresets = camera.zoomPresets())
        }
    }

    private fun label(index: Int, count: Int, front: Boolean): String {
        val side = if (front) "Front camera" else "Back camera"
        return if (count == 1) side else "$side ${index + 1}"
    }

    private fun sameFocal(a: Float, b: Float) = abs(a - b) < 0.15f

    private class Camera(private val manager: CameraManager, val id: String) {
        private val characteristics = manager.getCameraCharacteristics(id)

        val front = characteristics.get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_FRONT

        val focal = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.minOrNull() ?: 0f

        private val sensor: SizeF = characteristics
            .get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: SizeF(1f, 1f)

        val sensorArea = sensor.width * sensor.height

        private val zoomRange =
            characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
        val minZoom = zoomRange?.lower ?: 1f
        val maxZoom = zoomRange?.upper ?: 1f

        private val lenses: List<Pair<Float, SizeF>> = buildList {
            add(focal to sensor)
            for (physicalId in characteristics.physicalCameraIds) {
                runCatching {
                    val lens = manager.getCameraCharacteristics(physicalId)
                    val lensFocal = lens
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.minOrNull()
                    val lensSensor =
                        lens.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                    if (lensFocal != null && lensSensor != null) lensFocal to lensSensor
                    else null
                }.getOrNull()?.let { add(it) }
            }
        }

        /** Focal lengths of every lens this camera can switch to, its own included. */
        val lensFocals: List<Float> = lenses.map { it.first }.distinct()

        fun coversFocal(other: Float) = lensFocals.any { sameFocal(it, other) }

        /**
         * Zoom factors that land on this camera's lenses — the 0.6× and 3× a phone's
         * own camera app offers. A lens's "×" is the ratio of its field of view to
         * the reference lens's, which is what those numbers have always meant.
         */
        fun zoomPresets(): List<Float> {
            val steps = lenses
                .map { (lensFocal, lensSensor) -> round(zoomFactor(lensFocal, lensSensor)) }
                .filter { it in minZoom..maxZoom }
                .distinct()
                .sorted()
            return if (steps.size > 1) steps else emptyList()
        }

        /** Half-angle tangents compare fields of view without any trigonometry. */
        private fun zoomFactor(lensFocal: Float, lensSensor: SizeF): Float {
            val own = sensor.width / (2 * focal)
            val lens = lensSensor.width / (2 * lensFocal)
            return if (lens > 0f) own / lens else 1f
        }

        private fun round(value: Float) =
            if (value < 1f) (value * 10).roundToInt() / 10f else value.roundToInt().toFloat()
    }
}
