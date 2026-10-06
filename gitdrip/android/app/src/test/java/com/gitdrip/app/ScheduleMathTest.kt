package com.gitdrip.app

import com.gitdrip.app.data.*
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

class ScheduleMathTest {
    private val utc = ZoneId.of("UTC")
    private fun ms(s: String, z: ZoneId = utc) = ZonedDateTime.parse(s).withZoneSameInstant(z).toInstant().toEpochMilli()

    @Test fun timeValidation() {
        assertTrue(validTime("09:05")); assertTrue(validTime("23:59"))
        assertFalse(validTime("24:00")); assertFalse(validTime("9:05")); assertFalse(validTime("09:60"))
    }
    @Test fun zoneValidation() {
        assertTrue(validZone("")); assertTrue(validZone("Asia/Dhaka")); assertFalse(validZone("Mars/Base"))
    }
    @Test fun laterToday() =
        assertEquals(ms("2026-10-05T09:00:00Z"), nextFire(ms("2026-10-05T08:00:00Z"), "09:00", utc, ALL_DAYS))
    @Test fun rollsToTomorrow() =
        assertEquals(ms("2026-10-06T09:00:00Z"), nextFire(ms("2026-10-05T09:00:00Z"), "09:00", utc, ALL_DAYS))   // strictly after now
    @Test fun weekdayMask() {   // 2026-10-05 is a Monday; only Wed (bit2) -> 2026-10-07
        assertEquals(ms("2026-10-07T09:00:00Z"), nextFire(ms("2026-10-05T10:00:00Z"), "09:00", utc, 1 shl 2))
        assertNull(nextFire(ms("2026-10-05T10:00:00Z"), "09:00", utc, 0))
    }
    @Test fun zoneShiftsInstant() {
        val dhaka = ZoneId.of("Asia/Dhaka")   // UTC+6, no DST
        assertEquals(ms("2026-10-05T03:00:00Z"), nextFire(ms("2026-10-05T00:00:00Z"), "09:00", dhaka, ALL_DAYS))
    }
    @Test fun missedLogic() {
        val now = ms("2026-10-05T09:30:00Z")
        assertTrue(isMissed(now, "09:00", utc, ALL_DAYS, ""))
        assertFalse(isMissed(now, "09:00", utc, ALL_DAYS, "2026-10-05"))      // already fired
        assertFalse(isMissed(ms("2026-10-05T09:05:00Z"), "09:00", utc, ALL_DAYS, ""))   // within grace
        assertFalse(isMissed(now, "09:00", utc, 1 shl 2, ""))                  // Monday not selected
        assertFalse(isMissed(ms("2026-10-05T08:00:00Z"), "09:00", utc, ALL_DAYS, ""))   // slot not reached
    }
    @Test fun labels() {
        assertEquals("Every day", daysLabel(ALL_DAYS)); assertEquals("Mon Wed", daysLabel(0b101)); assertEquals("No days", daysLabel(0))
    }
}
