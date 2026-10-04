@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val FMT = DateTimeFormatter.ofPattern("MMM d, HH:mm")
fun fmtTime(ms: Long): String = FMT.format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

@Composable
private fun stateColor(s: String): Color = when (s) {
    "SUCCESS" -> MaterialTheme.colorScheme.primary
    "FAILED" -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

/** One run in a list. [project] is shown on the dashboard only. */
@Composable
fun RunRow(e: ExecutionEntity, project: String?, onOpen: (Long) -> Unit) {
    val detail = listOfNotNull(
        project, fmtTime(e.startedAt), e.commitHash?.take(7),
        if (e.filesChanged > 0) "${e.filesChanged} files" else null,
        e.reason?.takeIf { e.state != "SUCCESS" }?.take(60),
    ).joinToString(" · ")
    ListItem(
        headlineContent = { Text(e.state, color = stateColor(e.state)) },
        supportingContent = { Text(detail) },
        modifier = Modifier.clickable(onClickLabel = "Open run details", role = Role.Button) { onOpen(e.id) }.semantics(mergeDescendants = true) { },
    )
    HorizontalDivider()
}

@Composable
fun HistoryTab(vm: MainViewModel, p: ProjectEntity, onOpen: (Long) -> Unit) {
    val runs by vm.recentRuns(p.id).collectAsStateWithLifecycle(emptyList())
    val syncing by vm.syncing.collectAsStateWithLifecycle()
    val msg by vm.syncMsg.collectAsStateWithLifecycle()
    LaunchedEffect(p.id) { vm.sync(p) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton({ vm.sync(p) }, enabled = !syncing) { Text(if (syncing) "Syncing…" else "Sync from Termux") }
        }
        msg?.let { Text(it, Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall) }
        if (runs.isEmpty()) Text("No runs yet. Use ▶ on the Batches tab or add a schedule.", Modifier.padding(16.dp))
        else LazyColumn { items(runs, key = { it.id }) { RunRow(it, null, onOpen) } }
    }
}

@Composable
private fun Field(label: String, value: String) {
    if (value.isBlank()) return
    Column { Text(label, style = MaterialTheme.typography.labelSmall); SelectionContainer { Text(value) } }
}

@Composable
fun RunDetailScreen(vm: MainViewModel, id: Long, onBack: () -> Unit) {
    val e by vm.execution(id).collectAsStateWithLifecycle(null)
    val projects by vm.projects.collectAsStateWithLifecycle()
    val bridge by vm.bridge.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    Scaffold(topBar = {
        TopAppBar(title = { Text("Run", Modifier.asHeading()) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { pad ->
        val r = e
        if (r == null) { Box(Modifier.padding(pad).padding(24.dp)) { Text("Run not found") }; return@Scaffold }
        val p = projects.firstOrNull { it.id == r.projectId }
        val batch by produceState<BatchEntity?>(null, r.batchId) { value = r.batchId?.let { vm.batchById(it) } }
        Column(Modifier.padding(pad).padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(r.state, style = MaterialTheme.typography.headlineSmall, color = stateColor(r.state))
            Field("Project", p?.name ?: "(deleted)")
            Field("Batch", batch?.let { "#${it.seq} ${it.message}" } ?: "")
            Field("Started", fmtTime(r.startedAt))
            Field("Finished", r.finishedAt?.let { fmtTime(it) } ?: "")
            Field("Duration", if (r.finishedAt != null) durationLabel(r.startedAt, r.finishedAt) else "")
            Field("Commit", r.commitHash ?: "")
            Field("Files changed", if (r.filesChanged > 0) "${r.filesChanged}" else "")
            Field("Attempt", if (r.attempt > 0) "${r.attempt}" else "")
            Field("Next retry (UTC)", r.nextRetryAt)
            Field("Error class", r.errorClass)
            Field("Reason", r.reason ?: "")
            Field("Task", r.taskId)
            val url = r.commitHash?.let { h -> p?.let { commitUrl(it.repoUrl, h) } }
            if (url != null) OutlinedButton({ ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }) { Text("Open commit on GitHub") }
            val b = batch
            if (p != null && b != null && r.state in setOf("FAILED", "PENDING_RETRY") && b.status != "SUCCESS")
                Button({ vm.runBatch(p, b) }) { Text(if (r.state == "FAILED") "Retry this batch" else "Retry now") }
            bridge?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            if (r.output.isNotBlank()) {
                Text("Output (redacted)", style = MaterialTheme.typography.labelSmall)
                Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
                    SelectionContainer {
                        Text(redact(r.output), Modifier.padding(8.dp).horizontalScroll(rememberScrollState()),
                            fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}
