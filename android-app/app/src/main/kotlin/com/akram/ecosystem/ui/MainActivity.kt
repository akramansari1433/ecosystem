package com.akram.ecosystem.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.akram.ecosystem.service.ConnectionService

class MainActivity : ComponentActivity() {
    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        ConnectionService.start(this)
        setContent {
            MaterialTheme {
                StatusScreen()
            }
        }
    }

    /**
     * One UI only lets the focused app read the clipboard, so sync automatically
     * whenever this app comes to the foreground (echo suppression prevents loops).
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val service = ConnectionService.instance ?: return
        getSystemService(ClipboardManager::class.java).primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)?.coerceToText(this)?.toString()
            ?.takeIf { it.isNotEmpty() }
            ?.let(service::sendLocalClipboard)
    }
}

@Composable
fun StatusScreen() {
    val state by ConnectionService.state.collectAsState()

    Scaffold { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Ecosystem", style = MaterialTheme.typography.headlineMedium)

            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        when {
                            state.connected -> "Connected to ${state.peerName}"
                            state.paired -> "Paired — waiting for your Mac"
                            else -> "Not paired — open Ecosystem on your Mac"
                        },
                        style = MaterialTheme.typography.bodyLarge
                    )
                }
            }

            ClipboardSetupCard()

            state.pairing?.let { pairing ->
                when (pairing) {
                    is ConnectionService.PairingUi.AcceptPrompt -> AcceptDialog(pairing)
                    is ConnectionService.PairingUi.Code -> CodeDialog(pairing)
                }
            }
        }
    }
}

@Composable
private fun ClipboardSetupCard() {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Sending your clipboard to the Mac", fontWeight = FontWeight.SemiBold)
            Text(
                "Samsung only lets the app in focus read the clipboard, so pick " +
                    "whichever is easiest:\n" +
                    "•  Add the “Send clipboard to Mac” tile to Quick Settings — " +
                    "copy, swipe down, tap.\n" +
                    "•  Select text → Share → “Send to Mac”.\n" +
                    "•  Or just open this app — it syncs your clipboard automatically.",
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

@Composable
private fun AcceptDialog(prompt: ConnectionService.PairingUi.AcceptPrompt) {
    AlertDialog(
        onDismissRequest = { ConnectionService.instance?.userRejected() },
        title = { Text("Pair with a Mac?") },
        text = {
            Text("A Mac wants to pair with this phone.\n\nCertificate: " +
                prompt.fingerprint.take(16) + "…")
        },
        confirmButton = {
            Button(onClick = { ConnectionService.instance?.userAccepted() }) { Text("Accept") }
        },
        dismissButton = {
            TextButton(onClick = { ConnectionService.instance?.userRejected() }) { Text("Reject") }
        }
    )
}

@Composable
private fun CodeDialog(code: ConnectionService.PairingUi.Code) {
    AlertDialog(
        onDismissRequest = { ConnectionService.instance?.userRejected() },
        title = { Text("Confirm pairing code") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Make sure your Mac shows the same code:")
                Spacer(Modifier.height(12.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                    Text(
                        code.code,
                        fontSize = 40.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 6.sp
                    )
                }
            }
        },
        confirmButton = {
            Button(onClick = { ConnectionService.instance?.userConfirmed() }) { Text("They match") }
        },
        dismissButton = {
            TextButton(onClick = { ConnectionService.instance?.userRejected() }) { Text("Cancel") }
        }
    )
}
