package com.gitdrip.app.data

import java.io.File

/** Pure helpers for the P16b backup list. Name rule mirrors the engine (`_BR_BK_RE` in lib/bridge.sh). */
private val BACKUP_NAME = Regex("^gitdrip-(backup|config)-([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})\\.(tar\\.gz|json)$")

class BackupFile(val name: String, val size: Long, val isConfig: Boolean, val whenLabel: String)

fun validBackupName(name: String, ext: String): Boolean = BACKUP_NAME.matches(name) && name.endsWith(ext)

/** "gitdrip-backup-20261004-193005.tar.gz" -> "2026-10-04 19:30" (null when the name is not ours). */
fun backupWhen(name: String): String? = BACKUP_NAME.matchEntire(name)?.destructured?.let { (_, y, mo, d, h, mi, _, _) -> "$y-$mo-$d $h:$mi" }

fun humanSize(b: Long): String = when {
    b < 1024 -> "$b B"
    b < 1024 * 1024 -> "${b / 1024} KB"
    else -> String.format(java.util.Locale.US, "%.1f MB", b / 1048576.0)
}

/** Regular, non-symlink files with valid names only, newest first (names carry the timestamp). */
fun listBackups(dir: File): List<BackupFile> =
    (dir.listFiles() ?: emptyArray()).filter { it.isFile && !java.nio.file.Files.isSymbolicLink(it.toPath()) && BACKUP_NAME.matches(it.name) }
        .sortedByDescending { it.name.substringAfter('-').substringAfter('-') }
        .map { BackupFile(it.name, it.length(), it.name.startsWith("gitdrip-config-"), backupWhen(it.name) ?: "") }
