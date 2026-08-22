package com.akram.ecosystem.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Environment
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
    companion object {
        /** Android grants camera access to a service only while the app is visible. */
        @Volatile
        var isVisible = false
            private set
    }

    override fun onResume() {
        super.onResume()
        isVisible = true
        ConnectionService.instance?.onAppForeground()
    }

    override fun onPause() {
        isVisible = false
        super.onPause()
    }

    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    private val requestCamera =
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
                StatusScreen(
                    onAllowCamera = { requestCamera.launch(Manifest.permission.CAMERA) })
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
fun StatusScreen(
    onAllowCamera: () -> Unit = {},
) {
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
                            state.connectedPeers.size > 1 ->
                                "Connected to ${state.connectedPeers.joinToString(" and ")}"
                            state.connected -> "Connected to ${state.peerName}"
                            state.paired -> "Paired — waiting for your Mac"
                            else -> "Not paired — open Ecosystem on your Mac"
                        },
                        style = MaterialTheme.typography.bodyLarge
                    )
                }
            }

            if (state.cameraActive) {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text("Camera is streaming to your Mac",
                            fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            if (state.cameraPermissionNeeded) {
                CameraPermissionCard(onAllowCamera)
            }

            if (state.pairedMacs.isNotEmpty()) {
                PairedMacsCard(state.pairedMacs, state.connectedPeers)
            }

            PairByScanCard()

            ClipboardSetupCard()
            NotificationSetupCard()
            StorageSetupCard()

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
private fun PairedMacsCard(
    macs: List<com.akram.ecosystem.core.PairedPeers.Peer>,
    connected: List<String>,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Paired Macs", fontWeight = FontWeight.SemiBold)
            macs.forEach { mac ->
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(mac.name, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            if (mac.name in connected) "Connected" else "Not connected",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    TextButton(onClick = {
                        ConnectionService.instance?.unpair(mac.deviceId)
                    }) { Text("Remove") }
                }
            }
        }
    }
}

/**
 * Pairing by scanning the QR code the Mac shows. Uses Google's on-device code
 * scanner, so there is no camera permission to grant and no scanner UI to build.
 */
@Composable
private fun PairByScanCard() {
    val context = LocalContext.current
    var result by remember { mutableStateOf<String?>(null) }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Add a Mac", fontWeight = FontWeight.SemiBold)
            Text(
                result ?: "On the Mac, click the Ecosystem icon and choose “Pair by "
                    + "scanning”. Then scan the code it shows.",
                style = MaterialTheme.typography.bodyMedium
            )
            Button(onClick = {
                val options = com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
                    .Builder()
                    .setBarcodeFormats(com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE)
                    .enableAutoZoom()
                    .build()
                com.google.mlkit.vision.codescanner.GmsBarcodeScanning
                    .getClient(context, options)
                    .startScan()
                    .addOnSuccessListener { barcode ->
                        val value = barcode.rawValue
                        val name = value?.let {
                            ConnectionService.instance?.pairFromScan(it)
                        }
                        result = if (name != null) {
                            "Paired with $name. It will connect in a moment."
                        } else {
                            "That code was not an Ecosystem pairing code."
                        }
                    }
                    .addOnFailureListener { result = "Scanning failed: ${it.message}" }
                    .addOnCanceledListener { result = null }
            }) { Text("Scan QR code from Mac") }
        }
    }
}

@Composable
private fun CameraPermissionCard(onAllowCamera: () -> Unit) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(hasCameraPermission(context)) }
    LifecycleResumeEffect(Unit) {
        granted = hasCameraPermission(context)
        onPauseOrDispose { }
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (granted) {
                Text("Camera is allowed", fontWeight = FontWeight.SemiBold)
                Text("Press Start again in the camera window on your Mac.",
                    style = MaterialTheme.typography.bodyMedium)
            } else {
                Text("Your Mac wants to use this camera",
                    fontWeight = FontWeight.SemiBold)
                Button(onClick = onAllowCamera) { Text("Allow camera") }
            }
        }
    }
}

private fun hasCameraPermission(context: Context): Boolean =
    context.checkSelfPermission(Manifest.permission.CAMERA) ==
        PackageManager.PERMISSION_GRANTED

@Composable
private fun ClipboardSetupCard() {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(isAccessibilityEnabled(context)) }
    LifecycleResumeEffect(Unit) {
        enabled = isAccessibilityEnabled(context)
        onPauseOrDispose { }
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (enabled) {
                Text("Clipboard sync: automatic ✓", fontWeight = FontWeight.SemiBold)
                Text(
                    "Copy on either device, paste on the other. Backup options: the " +
                        "“Send clipboard to Mac” Quick Settings tile, or Share → " +
                        "“Send to Mac”.",
                    style = MaterialTheme.typography.bodyMedium
                )
            } else {
                Text("Phone → Mac clipboard is manual", fontWeight = FontWeight.SemiBold)
                Text(
                    "Enable the Ecosystem accessibility service to sync automatically " +
                        "whenever you copy.",
                    style = MaterialTheme.typography.bodyMedium
                )
                Button(onClick = {
                    context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                }) { Text("Open Accessibility settings") }
            }
        }
    }
}

@Composable
private fun NotificationSetupCard() {
    val context = LocalContext.current
    var enabled by remember {
        mutableStateOf(
            com.akram.ecosystem.notifications.NotificationRelay.isEnabled(context))
    }
    LifecycleResumeEffect(Unit) {
        enabled = com.akram.ecosystem.notifications.NotificationRelay.isEnabled(context)
        onPauseOrDispose { }
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (enabled) {
                Text("Notifications on your Mac: on ✓", fontWeight = FontWeight.SemiBold)
                Text(
                    "This phone's notifications appear on your Mac. Reply, answer " +
                        "calls, or dismiss them from there.",
                    style = MaterialTheme.typography.bodyMedium
                )
            } else {
                Text("See notifications on your Mac", fontWeight = FontWeight.SemiBold)
                Text(
                    "Grant notification access to show this phone's notifications " +
                        "on your Mac — including incoming calls, with Answer and " +
                        "Decline buttons.",
                    style = MaterialTheme.typography.bodyMedium
                )
                Button(onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                }) { Text("Open Notification access") }
            }
        }
    }
}

@Composable
private fun StorageSetupCard() {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(Environment.isExternalStorageManager()) }
    LifecycleResumeEffect(Unit) {
        granted = Environment.isExternalStorageManager()
        onPauseOrDispose { }
    }
    if (granted) return

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("File browsing needs storage access", fontWeight = FontWeight.SemiBold)
            Text(
                "Allow “All files access” so your Mac can browse this phone's storage.",
                style = MaterialTheme.typography.bodyMedium
            )
            Button(onClick = {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:${context.packageName}")))
            }) { Text("Grant storage access") }
        }
    }
}

private fun isAccessibilityEnabled(context: Context): Boolean =
    Settings.Secure.getString(
        context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        ?.contains(context.packageName) == true

@Composable
private fun AcceptDialog(prompt: ConnectionService.PairingUi.AcceptPrompt) {
    AlertDialog(
        onDismissRequest = { ConnectionService.instance?.userRejected() },
        title = { Text("Pair with a Mac?") },
        text = { Text("“${prompt.fingerprint}” wants to pair with this phone.") },
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
