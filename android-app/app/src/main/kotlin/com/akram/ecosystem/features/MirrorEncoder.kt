package com.akram.ecosystem.features

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import android.view.Surface
import com.akram.ecosystem.core.BinaryFrames
import kotlin.concurrent.thread

/**
 * Captures the screen via MediaProjection into a hardware H.264 encoder and
 * pushes Annex-B frames to [sink]. See docs/protocol.md §10.
 */
class MirrorEncoder(
    private val projection: MediaProjection,
    private val width: Int,
    private val height: Int,
    private val bitrateBps: Int,
    private val densityDpi: Int,
    /** Called from the drain thread: (frameType, ptsMicros, payload). */
    private val sink: (Int, Long, ByteArray) -> Unit,
) {
    @Volatile
    private var running = false
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var display: VirtualDisplay? = null
    private var configFrame: ByteArray? = null

    fun start() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // Keep emitting frames while the screen is static, and don't buffer.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            setInteger(MediaFormat.KEY_LATENCY, 0)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        this.codec = codec
        surface = codec.createInputSurface()
        codec.start()
        display = projection.createVirtualDisplay(
            "ecosystem-mirror", width, height, densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)
        running = true
        thread(name = "mirror-drain") { drainLoop(codec) }
        Log.i(TAG, "mirroring ${width}x$height @ ${bitrateBps / 1_000_000}Mbps")
    }

    fun stop() {
        running = false
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
                            // Some encoders deliver SPS/PPS here instead.
                            configFrame = data
                            sink(BinaryFrames.TYPE_CODEC_CONFIG, 0, data)
                        } else {
                            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (key) {
                                // Resend config before every keyframe: lets the Mac
                                // (re)join the stream at any keyframe boundary.
                                configFrame?.let { sink(BinaryFrames.TYPE_CODEC_CONFIG, 0, it) }
                            }
                            sink(
                                if (key) BinaryFrames.TYPE_KEYFRAME else BinaryFrames.TYPE_DELTA,
                                info.presentationTimeUs, data)
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "drain loop ended: $t")
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { display?.release() }
            runCatching { surface?.release() }
            runCatching { projection.stop() }
            Log.i(TAG, "mirroring stopped")
        }
    }

    private companion object {
        const val TAG = "MirrorEncoder"
    }
}
