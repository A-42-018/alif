@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.*

private val DAY_NAMES = listOf("M", "T", "W", "T", "F", "S", "S")

@Composable
fun ScheduleTab(vm: MainViewModel, p: ProjectEntity) {
    val ctx = LocalContext.current
    val list by vm.schedules(p.id).collectAsStateWithLifecycle(emptyList())
    val msg by vm.schedMsg.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<ScheduleEntity?>(null) }
    var adding by remember { mutableStateOf(false) }
    var exact by remember { mutableStateOf(Scheduler.canExact(ctx)) }
    LaunchedEffect(list) { exact = Scheduler.canExact(ctx) }
    Column(Modifier.fillMaxSize()) {
        if (!exact) Card(Modifier.padding(12.dp).fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                Text("Exact alarms are off: runs may be late. Allow \"Alarms & reminders\".", style = MaterialTheme.typography.bodySmall)
                TextButton({
                    ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${ctx.packageName}")))
                }) { Text("Allow exact alarms") }
            }
        }
        Row(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ adding = true }) { Icon(Icons.Default.Add, null); Text("Add time") }
            OutlinedButton({
                ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }) { Text("Battery") }
        }
        Text(
            "Disable battery optimization for GitDrip and Termux. Missed slots: skip, or run on boot/time change. Cap $DAILY_CAP/day.",
            Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall,
        )
        msg?.let { Text(it, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        if (list.isEmpty()) Text("No schedules. Each slot runs the next pending batch.", Modifier.padding(16.dp))
        LazyColumn {
            items(list, key = { it.id }) { s ->
                val at = nextFire(System.currentTimeMillis(), s.time, zoneOf(s.zone), s.days)
                ListItem(
                    headlineContent = { Text("${s.time}  ·  ${daysLabel(s.days)}") },
                    supportingContent = {
                        Text("${s.zone.ifEmpty { "device zone" }} · missed: ${s.policy}" +
                            (if (s.enabled && at != null) " · next ${java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(at)}" else ""))
                    },
                    trailingContent = {
                        Row {
                            Switch(s.enabled, { vm.setEnabled(s, it) }, Modifier.semantics { contentDescription = "Schedule ${s.time} enabled" })
                            IconButton({ vm.deleteSchedule(s) }) { Icon(Icons.Default.Delete, "Delete schedule") }
                        }
                    },
                    modifier = Modifier.clickable(onClickLabel = "Edit schedule ${s.time}", role = Role.Button) { editing = s },
                )
                HorizontalDivider()
            }
        }
    }
    if (adding || editing != null) ScheduleDialog(editing, onDismiss = { adding = false; editing = null }) { time, zone, days, policy ->
        vm.saveSchedule(p, editing, time, zone, days, policy); adding = false; editing = null
    }
}

@Composable
private fun ScheduleDialog(s: ScheduleEntity?, onDismiss: () -> Unit, onSave: (String, String, Int, String) -> Unit) {
    var time by remember(s) { mutableStateOf(s?.time ?: "09:00") }
    var zone by remember(s) { mutableStateOf(s?.zone ?: "") }
    var days by remember(s) { mutableIntStateOf(s?.days ?: ALL_DAYS) }
    var policy by remember(s) { mutableStateOf(s?.policy ?: "skip") }
    val err = when {
        !validTime(time) -> "Time must be HH:MM (24h)"
        !validZone(zone.trim()) -> "Unknown zone (e.g. Asia/Dhaka, UTC). Empty = device zone"
        days == 0 -> "Pick at least one day"
        else -> null
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (s == null) "New schedule" else "Edit schedule") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(time, { time = it.trim() }, label = { Text("Time HH:MM (24h)") }, singleLine = true)
                OutlinedTextField(zone, { zone = it }, label = { Text("Time zone (empty = device)") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    DAY_NAMES.forEachIndexed { i, n ->
                        FilterChip((days shr i) and 1 == 1, { days = days xor (1 shl i) }, label = { Text(n) })
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("skip", "run-now").forEach { o -> FilterChip(policy == o, { policy = o }, label = { Text("missed: $o") }) }
                }
                err?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = { TextButton({ onSave(time, zone.trim(), days, policy) }, enabled = err == null) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}
