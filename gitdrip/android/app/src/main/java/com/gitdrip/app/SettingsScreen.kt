@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.BackupFile
import com.gitdrip.app.data.Notify
import com.gitdrip.app.data.humanSize

/** P16b: notifications + backup / restore / config import-export. The engine (Termux) does the work; files live in GitDrip/backups. */
@Composable
fun SettingsScreen(vm: MainViewModel, onBack: () -> Unit) {
    val ctx = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { tick++; vm.refreshBackups() }
    val askNotif = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { tick++ }
    val granted = remember(tick) { Notify.granted(ctx) }
    var okNotes by remember(tick) { mutableStateOf(Notify.successEnabled(ctx)) }
    var full by remember { mutableStateOf(false) }
    var target by remember { mutableStateOf<BackupFile?>(null) }
    val files by vm.backups.collectAsStateWithLifecycle()
    val msg by vm.backupMsg.collectAsStateWithLifecycle()
    val busy by vm.backupBusy.collectAsStateWithLifecycle()

    Scaffold(topBar = {
        TopAppBar(title = { Text("Settings & backup", Modifier.asHeading()) }, navigationIcon = {
            IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        })
    }) { pad ->
        Column(Modifier.padding(pad).padding(horizontal = 16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Notifications", style = MaterialTheme.typography.titleSmall, modifier = Modifier.asHeading())
            if (!granted) {
                Text("Allow notifications to hear about failed runs while the app is closed.", style = MaterialTheme.typography.bodySmall)
                Button({ if (Build.VERSION.SDK_INT >= 33) askNotif.launch(Manifest.permission.POST_NOTIFICATIONS) }) { Text("Allow notifications") }
            } else Text("Failed runs always notify. Messages never contain tokens.", style = MaterialTheme.typography.bodySmall)
            LabeledSwitch("Also notify when a batch is pushed", okNotes, { okNotes = it; Notify.setSuccess(ctx, it) })

            HorizontalDivider()
            Text("Backup", style = MaterialTheme.typography.titleSmall, modifier = Modifier.asHeading())
            Text("Saved to GitDrip/backups (last 10 kept). Contains projects, batches, schedules, task history and config. Never your GitHub token.", style = MaterialTheme.typography.bodySmall)
            LabeledSwitch("Include repo and source folders (bigger)", full, { full = it })
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ vm.backupNow(full) }, enabled = !busy) { Text("Back up now") }
                OutlinedButton({ vm.exportConfig() }, enabled = !busy) { Text("Export config") }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            msg?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = if (it.contains("failed") || it.contains("no answer")) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary) }

            HorizontalDivider()
            Text("Saved files", style = MaterialTheme.typography.titleSmall, modifier = Modifier.asHeading())
            if (files.isEmpty()) Text("None yet.", style = MaterialTheme.typography.bodySmall)
            files.forEach { f ->
                ListItem(
                    headlineContent = { Text((if (f.isConfig) "Config · " else "Backup · ") + f.whenLabel) },
                    supportingContent = { Text(humanSize(f.size)) },
                    trailingContent = { OutlinedButton({ target = f }, enabled = !busy) { Text(if (f.isConfig) "Apply" else "Restore") } },
                )
            }
            Text(
                "After a restore: set your token again (Termux setup > Send token), run `gitdrip schedule install` if you use Termux cron, " +
                    "and re-create app projects with the same names to see their history again. The app's own database is not part of the backup; run Sync to rebuild it.",
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(16.dp))
        }
    }

    target?.let { f ->
        var force by remember(f) { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = { target = null },
            title = { Text(if (f.isConfig) "Apply this config?" else "Restore this backup?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(if (f.isConfig) "Only known settings with matching types are applied." else "Projects that already exist are refused unless you allow overwriting. Local repo and source folders are kept.")
                    if (!f.isConfig) LabeledSwitch("Overwrite existing projects", force, { force = it })
                }
            },
            confirmButton = { TextButton({ target = null; if (f.isConfig) vm.importConfig(f.name) else vm.restoreBackup(f.name, force) }) { Text(if (f.isConfig) "Apply" else "Restore") } },
            dismissButton = { TextButton({ target = null }) { Text("Cancel") } },
        )
    }
}
