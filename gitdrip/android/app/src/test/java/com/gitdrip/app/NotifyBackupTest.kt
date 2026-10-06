package com.gitdrip.app

import com.gitdrip.app.data.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class NotifyBackupTest {
    private val now = 1_800_000_000_000L
    private fun n(prev: String?, st: String, ok: Boolean = false, fin: Long? = now, reason: String? = "boom", commit: String? = "abcdef1234") =
        noteFor(prev, st, "demo", reason, commit, 2, ok, fin, now)

    @Test fun failureAlwaysNotifies() { val x = n("RUNNING", "FAILED")!!; assertTrue(x.failure); assertTrue(x.title.contains("demo")); assertEquals("boom", x.text) }
    @Test fun successOnlyWhenEnabledAndHasCommit() {
        assertNull(n("RUNNING", "SUCCESS", ok = false)); assertNotNull(n("RUNNING", "SUCCESS", ok = true))
        assertNull(n("RUNNING", "SUCCESS", ok = true, commit = ""))
        assertEquals("abcdef1 · 2 file(s)", n("PENDING", "SUCCESS", ok = true)!!.text)
    }
    @Test fun silentForRetrySkipRunningAndNoChange() {
        for (s in listOf("PENDING_RETRY", "SKIPPED", "RUNNING", "PENDING")) assertNull(s, n("PENDING", s, ok = true))
        assertNull(n("FAILED", "FAILED"))   // same state twice -> one notification only
    }
    @Test fun oldRunsNeverNotify() { assertNull(n(null, "FAILED", fin = now - NOTE_MAX_AGE_MS - 1)); assertNotNull(n(null, "FAILED", fin = now - 1000)) }
    @Test fun textIsRedacted() {
        val tok = "ghp_" + "a".repeat(36)
        val x = n("RUNNING", "FAILED", reason = "push failed with $tok")!!
        assertFalse(x.text.contains(tok)); assertTrue(x.text.length <= 120)
    }
    @Test fun blankReasonGetsHint() { assertEquals("open the run for details", n("RUNNING", "FAILED", reason = " ")!!.text) }

    @Test fun backupNameRules() {
        assertTrue(validBackupName("gitdrip-backup-20261004-193005.tar.gz", ".tar.gz"))
        assertTrue(validBackupName("gitdrip-config-20261004-193005.json", ".json"))
        assertFalse(validBackupName("gitdrip-config-20261004-193005.json", ".tar.gz"))
        for (bad in listOf("../gitdrip-backup-20261004-193005.tar.gz", "evil.tar.gz", "gitdrip-backup-2026-193005.tar.gz", "gitdrip-backup-20261004-193005.tar.gz/x", ""))
            assertFalse(bad, validBackupName(bad, ".tar.gz"))
    }
    @Test fun whenLabelAndSize() {
        assertEquals("2026-10-04 19:30", backupWhen("gitdrip-backup-20261004-193005.tar.gz")); assertNull(backupWhen("x"))
        assertEquals("512 B", humanSize(512)); assertEquals("3 KB", humanSize(3072)); assertEquals("1.5 MB", humanSize(1_572_864))
    }
    @Test fun listsOnlyValidNewestFirst() {
        val d = createTempDir()
        try {
            listOf("gitdrip-backup-20261001-100000.tar.gz", "gitdrip-backup-20261003-100000.tar.gz", "gitdrip-config-20261002-100000.json", "notes.txt", "evil.tar.gz")
                .forEach { File(d, it).writeText("x") }
            File(d, "gitdrip-backup-20261004-100000.tar.gz").mkdir()   // directory with a valid name is ignored
            val l = listBackups(d)
            assertEquals(listOf("gitdrip-backup-20261003-100000.tar.gz", "gitdrip-config-20261002-100000.json", "gitdrip-backup-20261001-100000.tar.gz"), l.map { it.name })
            assertTrue(l[1].isConfig)
        } finally { d.deleteRecursively() }
    }
}
