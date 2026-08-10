package com.akram.ecosystem.ui

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Turns the display on (and shows over the lock screen) when the Mac starts
 * mirroring, then gets out of the way. Screen capture only produces frames while
 * the display is awake, so this makes "mirror" work even if the phone is face
 * down on the desk with the screen off.
 */
class WakeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        getSystemService(android.app.KeyguardManager::class.java)
            ?.requestDismissKeyguard(this, null)
        Handler(Looper.getMainLooper()).postDelayed({ finish() }, 400)
    }
}
