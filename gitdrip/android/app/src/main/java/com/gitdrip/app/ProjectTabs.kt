@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.BatchEntity
import com.gitdrip.app.data.FileEntity
import com.gitdrip.app.data.Importer
import com.gitdrip.app.data.ProjectEntity

@Composable
fun FilesTab(vm: MainViewModel, p: ProjectEntity) {
    val ctx = LocalContext.current
    val files by vm.files(p.id).collectAsStateWithLifecycle(emptyList())
    val batches by vm.batches(p.id).collectAsStateWithLifecycle(emptyList())
    val status by vm.status.collectAsStateWithLifecycle()
    var pick by remember { mutableStateOf<FileEntity?>(null) }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { u ->
        if (u != null) vm.importFrom(p, Importer.Kind.FOLDER, listOf(u))
    }
    val many = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { l ->
        if (l.isNotEmpty()) vm.importFrom(p, Importer.Kind.FILES, l)
    }
    val zip = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { u ->
        if (u != null) vm.importFrom(p, Importer.Kind.ZIP, listOf(u))
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton({ folder.launch(null) }) { Text("Folder") }
            OutlinedButton({ many.launch(arrayOf("*/*")) }) { Text("Files") }
            OutlinedButton({ zip.launch(arrayOf("application/zip", "application/x-zip-compressed")) }) { Text("ZIP") }
        }
        if (!vm.sharedAccess) Card(Modifier.padding(horizontal = 12.dp).fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                Text("Termux can't read app-private storage. Grant \"All files access\" so files go to /storage/emulated/0/GitDrip.", style = MaterialTheme.typography.bodySmall)
                TextButton({
                    ctx.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${ctx.packageName}")))
                }) { Text("Open settings") }
            }
        }
        status?.let { Text(it, Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall) }
        if (files.isEmpty()) Text("No files yet. Import a folder, files or a ZIP.", Modifier.padding(16.dp))
        else {
            Text("${files.size} files · secrets (.env, keys) are never copied", Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelMedium)
            val seq = batches.associate { it.id to it.seq }
            LazyColumn {
                items(files, key = { it.id }) { f ->
                    ListItem(
                        headlineContent = { Text(f.path) },
                        supportingContent = { Text("${f.size} B · ${f.sha256.take(10)}") },
                        trailingContent = { Text(f.batchId?.let { "#${seq[it]}" } ?: "–") },
                        modifier = Modifier.clickable { pick = f },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
    pick?.let { f ->
        AlertDialog(
            onDismissRequest = { pick = null },
            title = { Text("Assign ${f.path.substringAfterLast('/')}") },
            text = {
                LazyColumn {
                    item { TextButton({ vm.assign(p, f.id, null); pick = null }) { Text("Unassigned") } }
                    items(batches, key = { it.id }) { b ->
                        TextButton({ vm.assign(p, f.id, b.id); pick = null }) { Text("#${b.seq} ${b.message}") }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton({ pick = null }) { Text("Cancel") } },
        )
    }
}

@Composable
fun BatchesTab(vm: MainViewModel, p: ProjectEntity) {
    val batches by vm.batches(p.id).collectAsStateWithLifecycle(emptyList())
    val files by vm.files(p.id).collectAsStateWithLifecycle(emptyList())
    val status by vm.status.collectAsStateWithLifecycle()
    val bridge by vm.bridge.collectAsStateWithLifecycle()
    var edit by remember { mutableStateOf<BatchEntity?>(null) }
    var adding by remember { mutableStateOf(false) }
    val count = files.groupingBy { it.batchId }.eachCount()
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ vm.autoBatches(p) }) { Text("Auto-suggest") }
            OutlinedButton({ adding = true }) { Text("New batch") }
            FilledTonalButton({ vm.runBatch(p, null) }) { Text("Run next") }
        }
        status?.let { Text(it, Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall) }
        bridge?.let { Text(it, Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall) }
        Text("Unassigned files: ${count[null] ?: 0}", Modifier.padding(12.dp), style = MaterialTheme.typography.labelMedium)
        LazyColumn {
            items(batches, key = { it.id }) { b ->
                ListItem(
                    headlineContent = { Text("#${b.seq} ${b.message}") },
                    supportingContent = { Text("${count[b.id] ?: 0} files · ${b.status}") },
                    trailingContent = {
                        Row {
                            if (b.status == "PENDING" || b.status == "COMMITTED" || b.status == "FAILED")
                                IconButton({ vm.runBatch(p, b) }) { Icon(Icons.Default.PlayArrow, "Run this batch now") }
                            IconButton({ vm.moveBatch(p, b.id, -1) }) { Icon(Icons.Default.KeyboardArrowUp, "Move up") }
                            IconButton({ vm.moveBatch(p, b.id, 1) }) { Icon(Icons.Default.KeyboardArrowDown, "Move down") }
                            IconButton({ vm.deleteBatch(p, b.id) }) { Icon(Icons.Default.Delete, "Delete batch") }
                        }
                    },
                    modifier = Modifier.clickable { edit = b },
                )
                HorizontalDivider()
            }
        }
    }
    if (adding || edit != null) {
        var text by remember(edit, adding) { mutableStateOf(edit?.message ?: "") }
        AlertDialog(
            onDismissRequest = { adding = false; edit = null },
            title = { Text(if (edit == null) "New batch" else "Commit message") },
            text = { OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("feat: add …") }) },
            confirmButton = {
                TextButton({
                    edit?.let { vm.rename(p, it.id, text) } ?: vm.addBatch(p, text)
                    adding = false; edit = null
                }) { Text("Save") }
            },
            dismissButton = { TextButton({ adding = false; edit = null }) { Text("Cancel") } },
        )
    }
}
