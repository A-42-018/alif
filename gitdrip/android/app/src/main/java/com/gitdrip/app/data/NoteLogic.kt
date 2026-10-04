package com.gitdrip.app.data

class NoteSpec(val title: String, val text: String, val failure: Boolean)

const val NOTE_MAX_AGE_MS = 30 * 60_000L

/**
 * Pure: what (if anything) to tell the user when a run goes from [prev] to [now].
 * Only real transitions notify; runs that finished long ago (first history sync) never do.
 * Failures always notify; successes only when [notifySuccess]; retries/skips stay silent (Termux retries by itself).
 */
fun noteFor(
    prev: String?, now: String, project: String, reason: String?, commit: String?, files: Int,
    notifySuccess: Boolean, finishedAt: Long?, nowMs: Long,
): NoteSpec? {
    if (prev == now) return null
    if (finishedAt != null && nowMs - finishedAt > NOTE_MAX_AGE_MS) return null
    return when (now) {
        "FAILED" -> NoteSpec("Run failed · $project", redact(reason?.takeIf { it.isNotBlank() } ?: "open the run for details").take(120), true)
        "SUCCESS" -> if (notifySuccess && !commit.isNullOrEmpty()) NoteSpec("Pushed · $project", "${commit.take(7)} · $files file(s)", false) else null
        else -> null
    }
}
