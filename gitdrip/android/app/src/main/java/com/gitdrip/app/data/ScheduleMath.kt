package com.gitdrip.app.data

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** Pure schedule logic (no Android). days = bitmask, bit0 = Mon … bit6 = Sun. */
const val ALL_DAYS = 127
const val MISSED_GRACE_MIN = 10L
const val DAILY_CAP = 3            // mirrors engine config max_commits_per_day
private val TIME_RE = Regex("^([01][0-9]|2[0-3]):[0-5][0-9]$")

fun validTime(s: String) = TIME_RE.matches(s)
fun validZone(z: String) = z.isEmpty() || z in ZoneId.getAvailableZoneIds()
/** "" = follow the device zone (also after a timezone change). */
fun zoneOf(z: String): ZoneId = if (z.isEmpty()) ZoneId.systemDefault() else ZoneId.of(z)

fun dayAllowed(days: Int, d: LocalDate) = (days shr (d.dayOfWeek.value - 1)) and 1 == 1
fun dayKey(nowMs: Long, zone: ZoneId): String = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().toString()

private fun slotMs(d: LocalDate, time: String, zone: ZoneId): Long =
    ZonedDateTime.of(d, LocalTime.parse(time), zone).toInstant().toEpochMilli()   // DST gap shifts forward

/** Next fire strictly after [nowMs], or null when no day is selected. */
fun nextFire(nowMs: Long, time: String, zone: ZoneId, days: Int): Long? {
    val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    for (i in 0L..8L) {
        val d = today.plusDays(i)
        if (!dayAllowed(days, d)) continue
        val s = slotMs(d, time, zone)
        if (s > nowMs) return s
    }
    return null
}

/** Today's slot passed by more than the grace period and it has not fired today (boot / time-change catch-up). */
fun isMissed(nowMs: Long, time: String, zone: ZoneId, days: Int, lastFireDay: String, graceMin: Long = MISSED_GRACE_MIN): Boolean {
    val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    return dayAllowed(days, today) && lastFireDay != today.toString() &&
        nowMs > slotMs(today, time, zone) + graceMin * 60_000
}

fun daysLabel(days: Int): String {
    if (days == ALL_DAYS) return "Every day"
    val n = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    return n.filterIndexed { i, _ -> (days shr i) and 1 == 1 }.joinToString(" ").ifEmpty { "No days" }
}
