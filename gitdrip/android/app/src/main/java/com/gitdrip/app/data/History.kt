package com.gitdrip.app.data

import java.time.Instant
import java.time.LocalDate

/** Pure history/stats helpers (P12, no Android). */
class HistoryTask(
    val id: String, val batchId: Int?, val state: String, val commit: String, val filesChanged: Int, val attempt: Int,
    val reason: String, val output: String, val errorClass: String, val nextRetryAt: String,
    val createdAt: String, val startedAt: String, val finishedAt: String,
)

/** Terminal = nothing changes without a new run. PENDING_RETRY / PENDING / RUNNING are still live. */
fun isTerminal(s: String) = s in setOf("SUCCESS", "FAILED", "SKIPPED", "ERROR")

private val REDACTIONS = listOf(
    Regex("(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})") to "***",
    Regex("(?i)(authorization:?\\s*(?:bearer|basic|token)?\\s*)[^\\s\"']+") to "\$1***",
    Regex("(?i)\\b(password|passwd|token|secret|api[_-]?key)(\\s*[=:]\\s*)[^\\s\"']+") to "\$1\$2***",
    Regex("https://[^/\\s:@]+:[^@\\s]+@") to "https://***@",
    Regex("-----BEGIN [A-Z ]*PRIVATE KEY-----") to "[private key]",
    Regex("(auth-handoff\\s+[A-Za-z0-9-]+\\s+)[0-9a-f]{64}") to "\$1***",
)

/** Second line of defence: the engine already redacts, but anything stored in Room or shown passes here too. */
fun redact(s: String): String = REDACTIONS.fold(s) { acc, (re, rep) -> re.replace(acc, rep) }

/** Commit page for a github.com repo URL; null for anything else (no guessing). */
fun commitUrl(repo: String, hash: String): String? {
    val r = repo.trim().removeSuffix("/").removeSuffix(".git")
    return if (r.startsWith("https://github.com/") && Regex("^[0-9a-f]{7,40}$").matches(hash)) "$r/commit/$hash" else null
}

fun isoMs(s: String): Long? = try { Instant.parse(s).toEpochMilli() } catch (e: Exception) { null }

fun durationLabel(start: Long, end: Long?): String {
    if (end == null) return "—"
    val s = ((end - start) / 1000).coerceAtLeast(0)
    return if (s < 60) "${s}s" else "${s / 60}m ${s % 60}s"
}

class CommitStats(val today: Int, val week: Int, val streak: Int)

/**
 * [commitDays] = one yyyy-MM-dd per pushed commit (device zone). week = Monday..today.
 * streak = consecutive days with >= 1 commit, ending today (or yesterday while today has none yet).
 */
fun commitStats(commitDays: List<String>, today: LocalDate): CommitStats {
    val n = commitDays.groupingBy { it }.eachCount()
    fun at(d: LocalDate) = n[d.toString()] ?: 0
    val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
    val week = (0L..6L).sumOf { at(monday.plusDays(it)) }
    var d = if (at(today) > 0) today else today.minusDays(1)
    var streak = 0
    while (at(d) > 0) { streak++; d = d.minusDays(1) }
    return CommitStats(at(today), week, streak)
}
