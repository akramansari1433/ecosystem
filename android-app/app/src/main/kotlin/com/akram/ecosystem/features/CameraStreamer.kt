package com.akram.ecosystem.features

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.view.Surface
import com.akram.ecosystem.core.BinaryFrames
import java.util.concurrent.Executor
import kotlin.concurrent.thread

/**
 * Streams a phone camera to the Mac: Camera2 renders straight into a hardware
 * H.264 encoder's input surface, so frames never travel through app memory.
 * See docs/protocol.md §11.
 */
class CameraStreamer(
    private val context: Context,
    private val width: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    /** Called from the drain thread: (frameType, ptsMicros, payload). */
    private val sink: (Int, Long, ByteArray) -> Unit,
) {
    private val cameraManager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }

    @Volatile
    private var running = false
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var configFrame: ByteArray? = null
    private var requestBuilder: android.hardware.camera2.CaptureRequest.Builder? = null
    @Volatile
    private var zoomRatio = 1f

    var height: Int = 0
        private set

    val isRunning: Boolean get() = running

    /** Starts the given camera id, or the first back camera when blank. */
    fun start(requestedId: String) {
        val cameraId = resolveId(requestedId) ?: error("no camera available")
        val size = chooseSize(cameraId)
        height = size.second
        // Must be set before the drain thread starts: it loops on this flag, and
        // if it sees false it exits and releases the surface the camera is about
        // to configure — which surfaced as "Error configuring streams: Broken pipe".
        running = true
        startEncoder(size.first, size.second)
        openCamera(cameraId)
        Log.i(TAG, "camera $cameraId starting ${size.first}x${size.second} @${fps}fps")
    }

    fun stop() {
        if (!running && device == null) return
        running = false
        runCatching { session?.close() }
        runCatching { device?.close() }
        session = null
        device = null
        // The drain loop releases the codec and surface as it exits, then this
        // shuts the camera thread down so no stale callback can be posted to it.
        handler.postDelayed({ thread.quitSafely() }, 300)
    }

    fun cachedConfig(): ByteArray? = configFrame

    /**
     * Zooming is how the telephoto lenses are reached: Android switches to them
     * behind the scenes, exactly as the phone's own camera app does.
     */
    fun setZoom(ratio: Float) {
        zoomRatio = ratio
        handler.post {
            val builder = requestBuilder ?: return@post
            val session = session ?: return@post
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, ratio)
            runCatching { session.setRepeatingRequest(builder.build(), null, handler) }
                .onFailure { Log.w(TAG, "zoom failed: $it") }
        }
    }

    fun requestKeyframe() {
        runCatching {
            codec?.setParameters(android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        }
    }

    private fun resolveId(requestedId: String): String? {
        val ids = cameraManager.cameraIdList
        if (requestedId.isNotEmpty() && requestedId in ids) return requestedId
        return ids.firstOrNull {
            cameraManager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: ids.firstOrNull()
    }

    /** Nearest supported encoder size to the requested width, 16:9 preferred. */
    private fun chooseSize(cameraId: String): Pair<Int, Int> {
        val map = cameraManager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val candidates = map?.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty()
        val best = candidates
            .filter { it.width <= 1920 && it.height <= 1080 }
            .minByOrNull { kotlin.math.abs(it.width - width) }
            ?: return width to (width * 9 / 16)
        return best.width to best.height
    }

    /**
     * Camera2 needs a surface that already exists and is fully configured when the
     * capture session is built. A surface from `createInputSurface()` is tied to
     * the codec's own lifecycle and Samsung rejects the session with
     * "Error configuring streams: Broken pipe". A *persistent* input surface is
     * the supported way to wire a camera into an encoder.
     */
    private fun startEncoder(w: Int, h: Int) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 0)
        }
        val surface = MediaCodec.createPersistentInputSurface()
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.setInputSurface(surface)
        this.codec = codec
        inputSurface = surface
        codec.start()
        thread(name = "camera-drain") { drainLoop(codec) }
    }

    @SuppressLint("MissingPermission") // the service checks CAMERA before starting
    private fun openCamera(cameraId: String) {
        cameraManager.openCamera(cameraId, executor, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                device = camera
                val surface = inputSurface ?: return
                val config = SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR,
                    listOf(OutputConfiguration(surface)),
                    executor,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(configured: CameraCaptureSession) {
                            Log.i(TAG, "capture session configured")
                            session = configured
                            val builder = camera
                                .createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                .apply {
                                    addTarget(surface)
                                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                                        Range(fps, fps))
                                    set(CaptureRequest.CONTROL_ZOOM_RATIO, zoomRatio)
                                }
                            requestBuilder = builder
                            runCatching {
                                configured.setRepeatingRequest(builder.build(), null, handler)
                            }.onFailure { Log.e(TAG, "repeating request failed", it) }
                        }

                        override fun onConfigureFailed(s: CameraCaptureSession) {
                            Log.e(TAG, "capture session configuration failed")
                            stop()
                        }
                    })
                runCatching { camera.createCaptureSession(config) }
                    .onFailure { Log.e(TAG, "createCaptureSession failed", it) }
            }

            override fun onDisconnected(camera: CameraDevice) {
                Log.w(TAG, "camera disconnected")
                stop()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                Log.e(TAG, "camera error $error")
                stop()
            }
        })
    }

    private fun drainLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, 100_000)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        val csd0 = f.getByteBuffer("csd-0")
                        val csd1 = f.getByteBuffer("csd-1")
                        if (csd0 != null && csd1 != null) {
                            val config = ByteArray(csd0.remaining() + csd1.remaining())
                            csd0.get(config, 0, csd0.remaining())
                            csd1.get(config, config.size - csd1.remaining(), csd1.remaining())
                            configFrame = config
                            sink(BinaryFrames.TYPE_CODEC_CONFIG, 0, config)
                        }
                    }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        val data = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(data)
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            configFrame = data
                            sink(BinaryFrames.TYPE_CODEC_CONFIG, 0, data)
                        } else {
                            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (key) {
                                configFrame?.let {
                                    sink(BinaryFrames.TYPE_CODEC_CONFIG, 0, it)
                                }
                            }
                            sink(
                                if (key) BinaryFrames.TYPE_KEYFRAME else BinaryFrames.TYPE_DELTA,
                                info.presentationTimeUs, data)
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "camera drain ended: $t")
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { inputSurface?.release() }
            inputSurface = null
            Log.i(TAG, "camera stopped")
        }
    }

    private companion object {
        const val TAG = "CameraStreamer"
    }
}
