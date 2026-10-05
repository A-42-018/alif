package com.gitdrip.app

import com.gitdrip.app.data.*
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class HistoryTest {
    private val today = LocalDate.of(2026, 10, 7)   // Wednesday

    @Test fun statsCountTodayWeekAndStreak() {
        val s = commitStats(listOf("2026-10-07", "2026-10-07", "2026-10-06", "2026-10-05", "2026-10-02"), today)
        assertEquals(2, s.today); assertEquals(4, s.week); assertEquals(3, s.streak)   // week = Mon 10-05..; 10-02 is last week
    }
    @Test fun streakSurvivesUntilTodayHasACommit() {
        assertEquals(2, commitStats(listOf("2026-10-06", "2026-10-05"), today).streak)   // yesterday counts while today is empty
        assertEquals(0, commitStats(listOf("2026-10-04"), today).streak)                  // gap -> broken
        assertEquals(0, commitStats(emptyList(), today).streak)
    }
    @Test fun weekStartsMonday() {
        val sun = LocalDate.of(2026, 10, 4)   // Sunday: week = Mon 09-28..Sun 10-04
        assertEquals(2, commitStats(listOf("2026-09-28", "2026-10-04", "2026-09-27"), sun).week)
    }
    @Test fun redactsTokensAndSecrets() {
        val t = "push ghp_" + "a".repeat(36) + " Authorization: Bearer abc.def password=hunter2 https://u:pw@github.com/o/r"
        val r = redact(t)
        assertFalse(r.contains("ghp_")); assertFalse(r.contains("abc.def")); assertFalse(r.contains("hunter2")); assertFalse(r.contains("pw@"))
        assertEquals("plain output stays", redact("plain output stays"))
    }
    @Test fun commitUrlOnlyForGithubAndRealHashes() {
        assertEquals("https://github.com/o/r/commit/abc1234", commitUrl("https://github.com/o/r.git", "abc1234"))
        assertEquals("https://github.com/o/r/commit/abc1234", commitUrl("https://github.com/o/r/", "abc1234"))
        assertNull(commitUrl("https://gitlab.com/o/r", "abc1234")); assertNull(commitUrl("", "abc1234")); assertNull(commitUrl("https://github.com/o/r", "zz"))
    }
    @Test fun isoAndDuration() {
        assertEquals(1_800_000_000_000L, isoMs("2027-01-15T08:00:00Z")); assertNull(isoMs("")); assertNull(isoMs("garbage"))
        assertEquals("45s", durationLabel(0, 45_000)); assertEquals("2m 5s", durationLabel(0, 125_000)); assertEquals("—", durationLabel(0, null))
    }
    @Test fun terminalStates() {
        assertTrue(isTerminal("SUCCESS")); assertTrue(isTerminal("FAILED")); assertTrue(isTerminal("SKIPPED"))
        assertFalse(isTerminal("PENDING_RETRY")); assertFalse(isTerminal("RUNNING"))
    }
}
