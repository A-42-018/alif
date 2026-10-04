@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.Importer
import com.gitdrip.app.data.TermuxBridge

@Composable
private fun Check(label: String, ok: Boolean, hint: String, action: (@Composable () -> Unit)? = null) = ListItem(
    headlineContent = { Text((if (ok) "✓ " else "✗ ") + label) },
    supportingContent = { if (!ok) Text(hint) },
    trailingContent = if (!ok && action != null) ({ action() }) else null,
)

@Composable
fun SetupScreen(vm: MainViewModel, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val clip = LocalClipboardManager.current
    var tick by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { tick++ }
    val askPerm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { tick++ }
    val installed = remember(tick) { TermuxBridge.installed(ctx) }
    val permitted = remember(tick) { TermuxBridge.permitted(ctx) }
    val files = remember(tick) { Importer.sharedAccess() }
    val doctor by vm.doctor.collectAsStateWithLifecycle()
    val msg by vm.doctorMsg.collectAsStateWithLifecycle()
    Scaffold(topBar = {
        TopAppBar(title = { Text("Termux setup", Modifier.asHeading()) }, navigationIcon = {
            IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        })
    }) { pad ->
        Column(Modifier.padding(pad).padding(horizontal = 8.dp).verticalScroll(rememberScrollState())) {
            Check("Termux installed", installed, "Install Termux from F-Droid or GitHub (the Play Store build is outdated).")
            Check("Run-commands permission", permitted, "Lets GitDrip start the engine in Termux.") {
                Button({ askPerm.launch(TermuxBridge.PERM) }) { Text("Grant") }
            }
            Check("All-files access", files, "Termux can only read files in /storage/emulated/0/GitDrip.") {
                Button({
                    ctx.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${ctx.packageName}")))
                }) { Text("Open") }
            }
            Card(Modifier.padding(8.dp).fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("One-time setup in Termux", style = MaterialTheme.typography.titleSmall)
                    Text("1. Copy the extracted gitdrip/ engine folder to your phone's Download folder.\n2. Paste this in Termux:", style = MaterialTheme.typography.bodySmall)
                    SelectionContainer { Text(TermuxBridge.SETUP_COMMAND, style = MaterialTheme.typography.bodySmall) }
                    OutlinedButton({ clip.setText(AnnotatedString(TermuxBridge.SETUP_COMMAND)) }) { Text("Copy command") }
                    Text("3. Store your GitHub token in Termux (never in the app): echo YOUR_TOKEN | gitdrip auth set --user YOUR_NAME", style = MaterialTheme.typography.bodySmall)
                }
            }
            Button({ vm.checkEngine() }, Modifier.padding(8.dp).fillMaxWidth()) { Text("Test connection") }
            msg?.let { Text(it, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall) }
            doctor?.forEach { (label, ok) -> Check(label, ok, "Missing or not ready in Termux") }
            GitHubAccountCard(vm)
            Card(Modifier.padding(8.dp).fillMaxWidth()) {
                Text(
                    "Contributions: commits count on GitHub only with a verified/noreply author email, on the default branch of a non-fork repo. " +
                        "For private repos enable Profile → Contribution settings → \"Private contributions\". " +
                        "Also disable battery optimization for Termux.",
                    Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}
