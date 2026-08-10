package com.akram.ecosystem.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
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
