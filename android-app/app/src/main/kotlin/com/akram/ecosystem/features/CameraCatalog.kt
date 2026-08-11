package com.akram.ecosystem.features

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import com.akram.ecosystem.core.CameraDeviceInfo

/**
 * Describes the cameras this phone will actually let us open, with labels a
 * person recognises. A modern phone exposes several back cameras (ultra wide,
 * main, telephoto), so "front or back" is not enough to pick one.
 */
object CameraCatalog {

    fun list(context: Context): List<CameraDeviceInfo> {
        val manager = context.getSystemService(CameraManager::class.java)
        val entries = manager.cameraIdList.mapNotNull { id ->
            runCatching {
                val characteristics = manager.getCameraCharacteristics(id)
                val zoomRange =
                    characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                Entry(
                    id = id,
                    front = characteristics.get(CameraCharacteristics.LENS_FACING) ==
                        CameraCharacteristics.LENS_FACING_FRONT,
                    focal = characteristics
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.minOrNull() ?: 0f,
                    minZoom = zoomRange?.lower ?: 1f,
                    maxZoom = zoomRange?.upper ?: 1f)
            }.getOrNull()
        }

        val back = entries.filterNot { it.front }.sortedBy { it.focal }
        val front = entries.filter { it.front }.sortedBy { it.focal }
        // The main camera is the reference for zoom factors: on every phone it is
        // the second-shortest back lens when an ultra wide is present.
        val mainFocal = when {
            back.size >= 2 -> back[1].focal
            back.isNotEmpty() -> back[0].focal
            else -> 0f
        }

        return buildList {
            back.forEachIndexed { index, entry ->
                add(CameraDeviceInfo(
                    facing = "back",
                    id = entry.id,
                    label = backLabel(index, back.size, entry.focal, mainFocal),
                    maxZoom = entry.maxZoom,
                    minZoom = entry.minZoom))
            }
            front.forEachIndexed { index, entry ->
                add(CameraDeviceInfo(
                    facing = "front",
                    id = entry.id,
                    label = if (front.size > 1) "Front camera ${index + 1}" else "Front camera",
                    maxZoom = entry.maxZoom,
                    minZoom = entry.minZoom))
            }
        }
    }

    private fun backLabel(index: Int, count: Int, focal: Float, mainFocal: Float): String = when {
        count == 1 -> "Back camera"
        index == 0 && focal < mainFocal -> "Ultra wide"
        focal == mainFocal -> "Main camera"
        focal > mainFocal -> "Telephoto"
        else -> "Back camera ${index + 1}"
    }

    private data class Entry(
        val id: String,
        val front: Boolean,
        val focal: Float,
        val minZoom: Float,
        val maxZoom: Float,
    )
}
