@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val dark = isSystemInDarkTheme()
            val ctx = LocalContext.current
            val scheme = when {
                Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = scheme) { GitDripNav() }
        }
    }
}

@Composable
fun GitDripNav(vm: MainViewModel = viewModel()) {
    val nav = rememberNavController()
    NavHost(nav, "dashboard") {
        composable("dashboard") { Dashboard(vm, { nav.navigate("projects") }, { nav.navigate("setup") }, { nav.navigate("settings") }, { nav.navigate("run/$it") }) }
        composable("run/{id}", listOf(navArgument("id") { type = NavType.LongType })) { e ->
            RunDetailScreen(vm, e.arguments!!.getLong("id")) { nav.popBackStack() }
        }
        composable("setup") { SetupScreen(vm) { nav.popBackStack() } }
        composable("settings") { SettingsScreen(vm) { nav.popBackStack() } }
        composable("projects") {
            ProjectList(vm, { nav.popBackStack() }, { nav.navigate("new") }, { nav.navigate("project/$it") })
        }
        composable("new") { NewProject(vm) { nav.popBackStack() } }
        composable("project/{id}", listOf(navArgument("id") { type = NavType.LongType })) { e ->
            ProjectDetail(vm, e.arguments!!.getLong("id"), { nav.navigate("run/$it") }) { nav.popBackStack() }
        }
    }
}

@Composable
private fun Bar(title: String, onBack: (() -> Unit)? = null) = TopAppBar(
    title = { Text(title, Modifier.asHeading()) },
    navigationIcon = {
        if (onBack != null) IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
    },
)

@Composable
private fun Stat(label: String, value: Int, modifier: Modifier = Modifier) = Card(modifier.semantics(mergeDescendants = true) { contentDescription = "$label: $value" }) {
    Column(Modifier.padding(16.dp)) {
        Text("$value", style = MaterialTheme.typography.headlineMedium)
        Text(label, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun Dashboard(vm: MainViewModel, onProjects: () -> Unit, onSetup: () -> Unit, onSettings: () -> Unit, onRun: (Long) -> Unit) {
    val projects by vm.projects.collectAsStateWithLifecycle()
    val schedules by vm.activeSchedules.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val failed by vm.failedToday.collectAsStateWithLifecycle()
    val retrying by vm.retrying.collectAsStateWithLifecycle()
    val next by vm.nextRun.collectAsStateWithLifecycle()
    val runs by vm.latestRuns.collectAsStateWithLifecycle()
    val syncing by vm.syncing.collectAsStateWithLifecycle()
    val msg by vm.syncMsg.collectAsStateWithLifecycle()
    val names = projects.associate { it.id to it.name }
    Scaffold(topBar = { Bar("GitDrip") }) { pad ->
        LazyColumn(Modifier.padding(pad).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Projects", projects.size, Modifier.weight(1f)); Stat("Active schedules", schedules, Modifier.weight(1f))
            } }
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Commits today", stats.today, Modifier.weight(1f)); Stat("This week", stats.week, Modifier.weight(1f))
            } }
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Streak (days)", stats.streak, Modifier.weight(1f)); Stat("Failed today", failed, Modifier.weight(1f))
            } }
            if (retrying > 0) item { Text("$retrying run(s) waiting to retry in Termux", color = MaterialTheme.colorScheme.error) }
            item { Text(next?.let { "Next run: ${it.first} · ${fmtTime(it.second)}" } ?: "No upcoming runs (add a schedule)", style = MaterialTheme.typography.bodyMedium) }
            item { Button(onProjects, Modifier.fillMaxWidth()) { Text("Projects") } }
            item { OutlinedButton(onSetup, Modifier.fillMaxWidth()) { Text("Termux setup") } }
            item { OutlinedButton(onSettings, Modifier.fillMaxWidth()) { Text("Settings & backup") } }
            item { OutlinedButton({ vm.sync() }, Modifier.fillMaxWidth(), enabled = !syncing) { Text(if (syncing) "Syncing…" else "Sync all from Termux") } }
            msg?.let { item { Text(it, style = MaterialTheme.typography.bodySmall) } }
            item { Text("Recent runs", style = MaterialTheme.typography.titleSmall) }
            if (runs.isEmpty()) item { Text("No runs yet.") }
            items(runs, key = { it.id }) { RunRow(it, names[it.projectId] ?: "(deleted)", onRun) }
        }
    }
}

@Composable
fun ProjectList(vm: MainViewModel, onBack: () -> Unit, onNew: () -> Unit, onOpen: (Long) -> Unit) {
    val projects by vm.projects.collectAsStateWithLifecycle()
    Scaffold(
        topBar = { Bar("Projects", onBack) },
        floatingActionButton = {
            FloatingActionButton(onNew) { Icon(Icons.Default.Add, "New project") }
        },
    ) { pad ->
        if (projects.isEmpty()) {
            Box(Modifier.padding(pad).fillMaxSize().padding(24.dp)) { Text("No projects yet. Tap + to create one.") }
        } else LazyColumn(Modifier.padding(pad)) {
            items(projects, key = { it.id }) { p ->
                ListItem(
                    headlineContent = { Text(p.name) },
                    supportingContent = { Text(p.repoUrl.ifEmpty { "no repo set" } + " · " + p.branch) },
                    modifier = Modifier.clickable(onClickLabel = "Open project ${p.name}", role = Role.Button) { onOpen(p.id) },
                )
                HorizontalDivider()
            }
        }
    }
}

@Composable
fun NewProject(vm: MainViewModel, onDone: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var repo by remember { mutableStateOf("") }
    var branch by remember { mutableStateOf("main") }
    var error by remember { mutableStateOf<String?>(null) }
    var picker by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    if (picker) RepoPickerDialog(vm, { r, b -> repo = r; branch = b; picker = false }, { picker = false })
    Scaffold(topBar = { Bar("New project", onDone) }) { pad ->
        Column(Modifier.padding(pad).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Name (slug)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(repo, { repo = it }, label = { Text("GitHub repo URL (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedButton({ picker = true }, Modifier.fillMaxWidth()) { Text("Pick from my GitHub repos") }
            OutlinedTextField(branch, { branch = it }, label = { Text("Branch") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(
                onClick = { scope.launch { error = vm.create(name, repo, branch); if (error == null) onDone() } },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save") }
        }
    }
}

@Composable
fun ProjectDetail(vm: MainViewModel, id: Long, onRun: (Long) -> Unit, onBack: () -> Unit) {
    val project by vm.project(id).collectAsStateWithLifecycle(initialValue = null)
    val pending by vm.pending(id).collectAsStateWithLifecycle(initialValue = 0)
    var tab by remember { mutableIntStateOf(0) }
    var confirm by remember { mutableStateOf(false) }
    val tabs = listOf("Files" to "P9", "Batches" to "P9", "Schedule" to "P11", "History" to "P12")
    val p = project
    LaunchedEffect(p?.id) { p?.let { vm.reconcile(it) } }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(p?.name ?: "") },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = { IconButton({ confirm = true }) { Icon(Icons.Default.Delete, "Delete project") } },
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            if (p != null) Text(
                "${p.repoUrl.ifEmpty { "no repo set" }} · ${p.branch} · $pending pending batches",
                Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium,
            )
            TabRow(tab) { tabs.forEachIndexed { i, t -> Tab(tab == i, { tab = i }, text = { Text(t.first) }) } }
            when {
                p == null -> {}
                tab == 0 -> FilesTab(vm, p)
                tab == 1 -> BatchesTab(vm, p)
                tab == 2 -> ScheduleTab(vm, p)
                else -> HistoryTab(vm, p, onRun)
            }
        }
    }
    if (confirm && p != null) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text("Delete '${p.name}'?") },
        text = { Text("Removes the project and its batches, schedules and history from the app. Termux files are not touched.") },
        confirmButton = { TextButton({ confirm = false; vm.delete(p); onBack() }) { Text("Delete") } },
        dismissButton = { TextButton({ confirm = false }) { Text("Cancel") } },
    )
}
