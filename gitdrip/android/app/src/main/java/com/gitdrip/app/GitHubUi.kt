@file:OptIn(ExperimentalMaterial3Api::class)

package com.gitdrip.app

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gitdrip.app.data.GhRepo
import com.gitdrip.app.data.filterRepos

/** Setup screen: asks the engine (Termux) who the stored token belongs to. The token itself never reaches the app. */
@Composable
fun GitHubAccountCard(vm: MainViewModel) {
    val acc by vm.ghAccount.collectAsStateWithLifecycle()
    val msg by vm.ghMsg.collectAsStateWithLifecycle()
    val busy by vm.ghBusy.collectAsStateWithLifecycle()
    Card(Modifier.padding(8.dp).fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("GitHub account", style = MaterialTheme.typography.titleSmall)
            Text("The token stays in Termux. GitDrip only asks the engine whom it belongs to.", style = MaterialTheme.typography.bodySmall)
            acc?.let {
                Text("✓ ${it.login} · ${it.tokenKind} token\nCommit author email: ${it.noreplyEmail}", style = MaterialTheme.typography.bodySmall)
                if (!it.userMatches) Text("Stored user name differs from the token owner. Re-run: echo TOKEN | gitdrip auth set --user ${it.login}",
                    color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            msg?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            OutlinedButton({ vm.ghValidate() }, enabled = !busy) { Text(if (busy) "Checking…" else "Check token") }
            HorizontalDivider()
            TokenSection(vm)
        }
    }
}

private fun Context.findActivity(): Activity? = when (this) { is Activity -> this; is ContextWrapper -> baseContext.findActivity(); else -> null }

/** Blocks screenshots / recents thumbnails only while [enabled] (token field non-empty). */
@Composable
private fun SecureWindow(enabled: Boolean) {
    val w = LocalContext.current.findActivity()?.window
    DisposableEffect(w, enabled) {
        if (enabled) w?.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { w?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}

/** Paste a token once: encrypted file + one-time key -> Termux credentials. Optional Keystore copy for re-sending after a Termux reinstall. */
@Composable
private fun TokenSection(vm: MainViewModel) {
    val msg by vm.tokMsg.collectAsStateWithLifecycle()
    val busy by vm.tokBusy.collectAsStateWithLifecycle()
    val saved by vm.vaultHas.collectAsStateWithLifecycle()
    var user by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    SecureWindow(enabled = token.isNotEmpty())
    var keep by remember { mutableStateOf(false) }
    Text("Send token to Termux", style = MaterialTheme.typography.titleSmall)
    Text("Encrypted before it leaves the app; Termux stores it chmod 600. Fine-grained token: Contents read/write on the target repo only.", style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(user, { user = it.trim() }, label = { Text("GitHub user name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(token, { token = it.trim() }, label = { Text("Token") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrect = false))
    LabeledSwitch("Keep an encrypted copy on this device (Keystore)", keep, { keep = it })
    msg?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = if (it.startsWith("Token stored") || it.startsWith("Saved token removed")) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button({ vm.sendToken(user, token, keep); token = "" }, enabled = !busy && user.isNotEmpty() && token.isNotEmpty()) { Text(if (busy) "Sending…" else "Send") }
        if (saved) {
            OutlinedButton({ vm.resendSavedToken(user) }, enabled = !busy && user.isNotEmpty()) { Text("Re-send saved") }
            TextButton({ vm.forgetSavedToken() }, enabled = !busy) { Text("Forget saved") }
        }
    }
}

/** Two steps: pick a repo from the account, then a branch. Calls [onPick] with the https URL and branch. */
@Composable
fun RepoPickerDialog(vm: MainViewModel, onPick: (String, String) -> Unit, onDismiss: () -> Unit) {
    val repos by vm.ghRepos.collectAsStateWithLifecycle()
    val br by vm.ghBranches.collectAsStateWithLifecycle()
    val msg by vm.ghMsg.collectAsStateWithLifecycle()
    val busy by vm.ghBusy.collectAsStateWithLifecycle()
    var q by remember { mutableStateOf("") }
    var all by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<GhRepo?>(null) }
    LaunchedEffect(Unit) { vm.ghLoadRepos() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(picked?.fullName ?: "Your GitHub repositories") },
        text = {
            Column {
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                msg?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                val p = picked
                if (p == null) {
                    OutlinedTextField(q, { q = it }, label = { Text("Search") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    LabeledSwitch("Show forks / read-only", all, { all = it })
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        items(filterRepos(repos.orEmpty(), q, !all)) { r ->
                            ListItem(
                                headlineContent = { Text(r.fullName) },
                                supportingContent = {
                                    Text(listOfNotNull(if (r.isPrivate) "private" else "public", if (r.fork) "fork: commits won't count" else null,
                                        if (r.archived) "archived" else null, if (!r.push) "no push access" else null).joinToString(" · "))
                                },
                                modifier = Modifier.clickable { picked = r; vm.ghLoadBranches(r.fullName) },
                            )
                        }
                    }
                } else {
                    Text("Only the default branch counts toward your graph. Private repo? Enable \"Private contributions\" on GitHub.", style = MaterialTheme.typography.bodySmall)
                    LazyColumn(Modifier.heightIn(max = 280.dp)) {
                        items(br?.names.orEmpty()) { n ->
                            ListItem(headlineContent = { Text(n + if (n == br?.defaultBranch) "  (default)" else "") },
                                modifier = Modifier.clickable { onPick(p.url, n) })
                        }
                    }
                    TextButton({ picked = null }) { Text("Back") }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onDismiss) { Text("Close") } },
    )
}
