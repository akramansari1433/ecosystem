package com.akram.ecosystem.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings the connection service up without anyone opening the app: after a
 * reboot, and after the APK is updated in place. Without this the phone only
 * reconnects to the Mac once the user happens to launch Ecosystem.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> ConnectionService.start(context)
        }
    }
}
