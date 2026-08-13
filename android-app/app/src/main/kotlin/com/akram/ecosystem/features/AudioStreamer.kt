package com.akram.ecosystem.features

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.util.Log

/**
 * Captures what the phone is playing — music, videos, game audio — and hands
 * ~20 ms PCM chunks to [sink] so the Mac can play them during mirroring.
 * Rides the same MediaProjection consent as the video. Cellular call audio can
 * never appear here: Android excludes it at the platform level for every
 * non-system app, and individual apps may also opt their audio out of capture.
 */
class AudioStreamer(
    private val projection: MediaProjection,
    private val sink: (Long, ByteArray) -> Unit,
) {
    companion object {
        private const val TAG = "AudioStreamer"
        const val SAMPLE_RATE = 48_000
        const val CHANNELS = 2
        private const val BYTES_PER_FRAME = CHANNELS * 2      // 16-bit samples
        private const val CHUNK_BYTES = SAMPLE_RATE * BYTES_PER_FRAME / 50   // 20 ms
    }

    @Volatile
    private var running = false
    private var record: AudioRecord? = null

    /** Throws if RECORD_AUDIO is missing or the device refuses playback capture. */
    fun start() {
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val record = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build())
            .setBufferSizeInBytes(SAMPLE_RATE * BYTES_PER_FRAME / 5)   // 200 ms
            .build()
        this.record = record
        running = true
        record.startRecording()
        Thread({
            val chunk = ByteArray(CHUNK_BYTES)
            while (running) {
                val n = record.read(chunk, 0, chunk.size)
                if (n <= 0) continue
                sink(System.nanoTime() / 1_000, chunk.copyOf(n))
            }
        }, "audio-capture").start()
        Log.i(TAG, "capturing playback audio")
    }

    fun stop() {
        running = false
        runCatching { record?.stop() }
        runCatching { record?.release() }
        record = null
    }
}
