package com.gitdrip.app.data

// Pure logic (no Android deps) mirroring the Termux engine rules (lib/manifest.sh, lib/batch.sh).

data class FileEntry(val path: String, val size: Long, val sha256: String)
data class SuggestedBatch(val message: String, val paths: List<String>)

const val DEFAULT_BATCH_MAX = 5
private val SECRET_EXT = listOf(".pem", ".key", ".jks", ".keystore", ".p12", ".pfx")
private val DOC_EXT = listOf(".md", ".txt", ".rst", ".adoc")

/** Same exclusions as the engine: .env (not .env.example), ssh keys, certs/keystores. */
fun isSecretPath(path: String): Boolean {
    val n = path.substringAfterLast('/').lowercase()
    return n == ".env" || (n.startsWith(".env.") && n != ".env.example") ||
        n.startsWith("id_rsa") || n.startsWith("id_ed25519") || SECRET_EXT.any { n.endsWith(it) }
}

fun isSkippedPath(path: String): Boolean = path.split('/').any { it == ".git" || it == "node_modules" }

/** Normalises a relative path; null when unsafe (absolute, "..", empty, backslashes, NUL). Blocks zip-slip. */
fun sanitizePath(raw: String): String? {
    if (raw.isEmpty() || raw.startsWith("/") || raw.contains('\\') || raw.contains('\u0000')) return null
    val parts = raw.split('/').filter { it.isNotEmpty() && it != "." }
    if (parts.isEmpty() || parts.any { it == ".." }) return null
    return parts.joinToString("/")
}

private fun kindOf(paths: List<String>): String = when {
    paths.all { p -> DOC_EXT.any { p.lowercase().endsWith(it) } } -> "docs"
    paths.all { p -> p.lowercase().let { "test" in it || "spec" in it } } -> "test"
    else -> "feat"
}

/** One batch per directory module, at most [max] files each, split into "(part i/n)". Deterministic order. */
fun suggestBatches(files: List<FileEntry>, max: Int = DEFAULT_BATCH_MAX): List<SuggestedBatch> {
    require(max >= 1) { "max must be >= 1" }
    val usable = files.filter { !isSecretPath(it.path) && !isSkippedPath(it.path) }
    val out = ArrayList<SuggestedBatch>()
    usable.groupBy { it.path.substringBeforeLast('/', "") }.toSortedMap().forEach { (dir, group) ->
        val what = if (dir.isEmpty()) "project root files" else "$dir module"   // same wording as engine batch.sh
        val chunks = group.map { it.path }.sorted().chunked(max)
        chunks.forEachIndexed { i, paths ->
            val part = if (chunks.size > 1) " (part ${i + 1}/${chunks.size})" else ""
            out += SuggestedBatch("${kindOf(paths)}: add $what$part", paths)
        }
    }
    return out
}

/** Swap positions; returns the same list when the move is out of range. */
fun <T> List<T>.moved(index: Int, delta: Int): List<T> {
    val to = index + delta
    if (index !in indices || to !in indices) return this
    return toMutableList().also { val t = it[index]; it[index] = it[to]; it[to] = t }
}
