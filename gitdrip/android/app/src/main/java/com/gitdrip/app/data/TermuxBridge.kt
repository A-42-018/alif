package com.gitdrip.app.data

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

class PlanBatch(val seq: Int, val message: String, val files: List<String>)
class BatchState(val id: Int, val status: String, val commit: String)
class BridgeResult(
    val req: String, val state: String, val taskId: String, val commit: String, val reason: String,
    val exitCode: Int?, val filesChanged: Int, val batches: List<BatchState>,
    val output: String = "", val attempt: Int = 0, val nextRetryAt: String = "", val batchId: Int? = null,
) {
    val isFinal get() = isFinalState(state) || exitCode == 4   // 4 = project locked, task stays PENDING
}

/** Final = nothing more will change without a new user action (PENDING_RETRY is resolved by Termux cron/P12 sync). */
fun isFinalState(s: String) = s in setOf("SUCCESS", "FAILED", "SKIPPED", "ERROR", "OK", "PENDING_RETRY")

class HistoryResult(val tasks: List<HistoryTask>, val batches: List<BatchState>)

fun newRequestId(): String = "r" + System.currentTimeMillis().toString(36) + UUID.randomUUID().toString().take(6)

/** plan.json read by `gitdrip bridge <req> sync|run --sync`. Batches without files are dropped; engine id = rank by seq. */
fun buildPlan(project: String, repo: String, branch: String, batches: List<PlanBatch>): String =
    JSONObject().apply {
        put("project", project)
        if (repo.isNotEmpty()) put("repo", repo)
        put("branch", branch)
        put("batches", JSONArray().apply {
            batches.filter { it.files.isNotEmpty() }.sortedBy { it.seq }.forEach { b ->
                put(JSONObject().put("id", b.seq).put("message", b.message).put("files", JSONArray(b.files)))
            }
        })
    }.toString()

fun parseResult(json: String): BridgeResult? = try {
    val o = JSONObject(json)
    val bs = o.optJSONArray("batches") ?: JSONArray()
    BridgeResult(
        req = o.optString("req"), state = o.optString("state"), taskId = o.optString("task_id"),
        commit = o.optString("commit"), reason = o.optString("reason"),
        exitCode = if (o.has("exit_code") && !o.isNull("exit_code")) o.optInt("exit_code") else null,
        filesChanged = o.optInt("files_changed", 0),
        batches = batchStates(bs),
        output = o.optString("output"), attempt = o.optInt("attempt", 0), nextRetryAt = o.optString("next_retry_at"),
        batchId = if (o.has("batch_id") && !o.isNull("batch_id")) o.optInt("batch_id") else null,
    )
} catch (e: Exception) { null }   // half-written / foreign file -> treat as "not there yet"

private fun batchStates(a: JSONArray) = (0 until a.length()).map { i ->
    val b = a.getJSONObject(i); BatchState(b.optInt("id"), b.optString("status"), b.optString("commit"))
}

/** `bridge <req> history <p>` result; null unless state OK with a tasks array. */
fun parseHistory(json: String): HistoryResult? = try {
    val o = JSONObject(json)
    if (o.optString("state") != "OK" || !o.has("tasks")) null else {
        val ts = o.getJSONArray("tasks")
        HistoryResult((0 until ts.length()).map { i ->
            val t = ts.getJSONObject(i)
            HistoryTask(
                id = t.getString("id"), batchId = if (t.isNull("batch_id")) null else t.optInt("batch_id"), state = t.optString("state"),
                commit = t.optString("commit"), filesChanged = t.optInt("files_changed", 0), attempt = t.optInt("attempt", 0),
                reason = t.optString("reason"), output = t.optString("output"), errorClass = t.optString("error_class"),
                nextRetryAt = t.optString("next_retry_at"), createdAt = t.optString("created_at"),
                startedAt = t.optString("started_at"), finishedAt = t.optString("finished_at"),
            )
        }, batchStates(o.optJSONArray("batches") ?: JSONArray()))
    }
} catch (e: Exception) { null }

/** Doctor result -> ordered checklist (label to ok). Null when unparsable. */
fun parseDoctor(json: String): List<Pair<String, Boolean>>? = try {
    val o = JSONObject(json); val t = o.getJSONObject("tools")
    listOf("git" to t.optBoolean("git"), "curl" to t.optBoolean("curl"), "jq" to t.optBoolean("jq"), "openssl" to t.optBoolean("openssl"),
        "~/storage linked" to o.optBoolean("storage_link"), "exchange folder writable" to o.optBoolean("exchange_writable"),
        "GitHub token stored" to o.optBoolean("auth"))
} catch (e: Exception) { null }

object TermuxBridge {
    const val PKG = "com.termux"
    const val PERM = "com.termux.permission.RUN_COMMAND"
    private const val BIN = "/data/data/com.termux/files/usr/bin/gitdrip"
    private const val HOME = "/data/data/com.termux/files/home"

    /** One paste in Termux: shared storage, packages, allow-external-apps, then install the engine from Download/gitdrip. */
    val SETUP_COMMAND = "termux-setup-storage; pkg install -y git curl jq openssl-tool cronie termux-services; " +
        "mkdir -p ~/.termux; grep -qx 'allow-external-apps=true' ~/.termux/termux.properties 2>/dev/null || " +
        "echo 'allow-external-apps=true' >> ~/.termux/termux.properties; termux-reload-settings; " +
        "cp -r ~/storage/shared/Download/gitdrip ~/gitdrip && bash ~/gitdrip/install.sh"

    fun installed(c: Context) = try { c.packageManager.getPackageInfo(PKG, 0); true } catch (e: PackageManager.NameNotFoundException) { false }
    fun permitted(c: Context) = c.checkSelfPermission(PERM) == PackageManager.PERMISSION_GRANTED

    /** Fire-and-forget `gitdrip <args>` in Termux (background, no terminal). Returns an error message or null. */
    fun send(c: Context, args: List<String>): String? = try {
        val i = Intent("com.termux.RUN_COMMAND").setClassName(PKG, "com.termux.app.RunCommandService")
            .putExtra("com.termux.RUN_COMMAND_PATH", BIN)
            .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args.toTypedArray())
            .putExtra("com.termux.RUN_COMMAND_WORKDIR", HOME)
            .putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
        c.startForegroundService(i); null
    } catch (e: SecurityException) {
        "Termux refused: grant the Run-command permission and set allow-external-apps=true"
    } catch (e: Exception) { "Could not reach Termux: ${e.message}" }

    fun resultFile(c: Context, req: String) = File(Importer.baseDir(c), "results/$req.json")
    fun readResult(c: Context, req: String): String? = resultFile(c, req).takeIf { it.isFile }?.readText()

    /** Deletes result files older than [days] (the engine never cleans results/). */
    fun pruneResults(c: Context, days: Long = 30) {
        val limit = System.currentTimeMillis() - days * 86_400_000
        File(Importer.baseDir(c), "results").listFiles()?.filter { it.isFile && it.lastModified() < limit }?.forEach { it.delete() }
    }

    /** Writes `<GitDrip>/<project>/plan.json` (source/ was written by the importer). */
    fun writePlan(c: Context, project: String, json: String) {
        val d = File(Importer.baseDir(c), project).apply { mkdirs() }
        File(d, "plan.json.tmp").writeText(json); File(d, "plan.json.tmp").renameTo(File(d, "plan.json"))
    }
}
