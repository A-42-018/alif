package com.gitdrip.app.data

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Copies SAF-picked files / folder / ZIP into `<GitDrip dir>/<project>/source` and hashes them (SHA-256). */
object Importer {
    enum class Kind { FOLDER, FILES, ZIP }
    class Result(val files: List<FileEntry>, val excluded: List<String>)

    private const val MAX_FILES = 3000
    private const val MAX_TOTAL = 300L shl 20   // 300 MB cap (also stops zip bombs)

    /** True when /storage/emulated/0/GitDrip is writable (All-files access), i.e. Termux can read it via ~/storage/shared. */
    fun sharedAccess(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    fun baseDir(c: Context): File =
        if (sharedAccess()) File(Environment.getExternalStorageDirectory(), "GitDrip")
        else File(c.getExternalFilesDir(null) ?: c.filesDir, "GitDrip")   // fallback: Termux cannot read this

    fun sourceDir(c: Context, project: String) = File(baseDir(c), "$project/source")

    fun run(c: Context, project: String, kind: Kind, uris: List<Uri>): Result {
        require(uris.isNotEmpty()) { "Nothing selected" }
        val dest = sourceDir(c, project)
        dest.deleteRecursively(); dest.mkdirs()
        val st = State(dest)
        when (kind) {
            Kind.FOLDER -> {
                val tree = uris[0]
                walk(c, tree, DocumentsContract.getTreeDocumentId(tree), "", st)
            }
            Kind.FILES -> uris.forEach { u -> c.contentResolver.openInputStream(u)?.use { st.add(name(c, u), it) } }
            Kind.ZIP -> c.contentResolver.openInputStream(uris[0])?.use { raw ->
                ZipInputStream(raw).use { z ->
                    generateSequence { z.nextEntry }.forEach { e -> if (!e.isDirectory) st.add(e.name, z) }
                }
            }
        }
        check(st.files.isNotEmpty()) { "No importable files found" }
        return Result(st.files.sortedBy { it.path }, st.excluded)
    }

    private class State(val dest: File) {
        val files = ArrayList<FileEntry>(); val excluded = ArrayList<String>(); var total = 0L
        private val seen = HashSet<String>()

        fun add(raw: String, input: InputStream) {
            val path = sanitizePath(raw) ?: return                    // unsafe path (zip-slip etc.) -> ignored
            if (isSkippedPath(path)) return
            if (isSecretPath(path)) { excluded += path; return }       // never copied
            if (!seen.add(path)) return
            check(files.size < MAX_FILES) { "Too many files (max $MAX_FILES)" }
            val out = File(dest, path)
            check(out.canonicalPath.startsWith(dest.canonicalPath + File.separator)) { "Unsafe path: $path" }
            out.parentFile?.mkdirs()
            val md = MessageDigest.getInstance("SHA-256"); var n = 0L
            out.outputStream().use { o ->
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val r = input.read(buf); if (r < 0) break
                    total += r; n += r
                    check(total <= MAX_TOTAL) { "Import larger than ${MAX_TOTAL shr 20} MB" }
                    md.update(buf, 0, r); o.write(buf, 0, r)
                }
            }
            files += FileEntry(path, n, md.digest().joinToString("") { "%02x".format(it) })
        }
    }

    private fun name(c: Context, u: Uri): String =
        c.contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: u.lastPathSegment?.substringAfterLast('/') ?: "file"

    private fun walk(c: Context, tree: Uri, docId: String, rel: String, st: State) {
        class Child(val id: String, val name: String, val dir: Boolean)
        val kids = ArrayList<Child>()
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        c.contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE),
            null, null, null,
        )?.use { q ->
            while (q.moveToNext()) kids += Child(q.getString(0), q.getString(1), q.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR)
        }
        for (k in kids) {
            val path = if (rel.isEmpty()) k.name else "$rel/${k.name}"
            if (k.dir) { if (k.name != ".git" && k.name != "node_modules") walk(c, tree, k.id, path, st) }
            else c.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, k.id))?.use { st.add(path, it) }
        }
    }
}
