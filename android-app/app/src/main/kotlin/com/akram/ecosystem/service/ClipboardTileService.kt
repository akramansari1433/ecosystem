package com.akram.ecosystem.service

import android.app.PendingIntent
import android.content.Intent
import android.service.quicksettings.TileService
import com.akram.ecosystem.ui.ClipboardSendActivity

/** Quick Settings tile: copy anywhere → swipe down → tap → clipboard lands on the Mac. */
class ClipboardTileService : TileService() {
    override fun onClick() {
        val intent = Intent(this, ClipboardSendActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivityAndCollapse(
            PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
    }
}
