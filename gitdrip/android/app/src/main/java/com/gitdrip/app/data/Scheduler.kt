package com.gitdrip.app.data

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.gitdrip.app.AlarmReceiver
import com.gitdrip.app.GitDripApp

/** AlarmManager glue (P11). One exact alarm per enabled schedule; the receiver re-arms the next one after each fire. */
object Scheduler {
    const val ACTION_FIRE = "com.gitdrip.app.FIRE"
    const val EXTRA_ID = "scheduleId"

    private fun pi(c: Context, id: Long, flags: Int = 0): PendingIntent? =
        PendingIntent.getBroadcast(
            c, id.toInt(),
            Intent(c, AlarmReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_ID, id),
            flags or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun am(c: Context) = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    fun canExact(c: Context) = am(c).canScheduleExactAlarms()

    fun cancel(c: Context, id: Long) {
        pi(c, id, PendingIntent.FLAG_NO_CREATE)?.let { am(c).cancel(it); it.cancel() }
    }

    /** Arms (or re-arms) the next occurrence. Falls back to an inexact idle-safe alarm when exact alarms are not granted. */
    fun arm(c: Context, s: ScheduleEntity, nowMs: Long = System.currentTimeMillis()) {
        cancel(c, s.id)
        if (!s.enabled) return
        val at = nextFire(nowMs, s.time, zoneOf(s.zone), s.days) ?: return
        val p = pi(c, s.id, PendingIntent.FLAG_UPDATE_CURRENT)!!
        if (canExact(c)) am(c).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
        else am(c).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
    }

    suspend fun armAll(c: Context) {
        val db = (c.applicationContext as GitDripApp).db
        db.schedules().enabled().forEach { arm(c, it) }
    }

    /**
     * Alarm / catch-up entry point. Always re-arms in `finally`.
     * Sends ONE `bridge run <project> --sync` to Termux (fire-and-forget; open execution is reconciled
     * from results/<req>.json when the project is opened, full sync = P12).
     */
    suspend fun fire(c: Context, id: Long, catchUp: Boolean = false) {
        val db = (c.applicationContext as GitDripApp).db
        val s = db.schedules().byId(id) ?: run { cancel(c, id); return }
        try {
            if (!s.enabled) return
            val now = System.currentTimeMillis()
            val zone = zoneOf(s.zone); val today = dayKey(now, zone)
            if (s.lastFireDay == today) return                       // already ran today's slot
            if (!dayAllowed(s.days, java.time.LocalDate.parse(today))) return
            db.schedules().markFired(s.id, today)
            val ex = db.executions()
            val p = db.projects().byIdNow(s.projectId) ?: return
            suspend fun skipped(why: String) = ex.insert(ExecutionEntity(projectId = p.id, taskId = "", state = "SKIPPED", reason = why, startedAt = now, finishedAt = now))
            suspend fun failed(why: String) {
                val id = ex.insert(ExecutionEntity(projectId = p.id, taskId = "", state = "FAILED", reason = why, startedAt = now, finishedAt = now))
                noteFor(null, "FAILED", p.name, why, null, 0, false, now, now)?.let { Notify.post(c, id, it) }
            }
            if (p.paused) { skipped("project paused"); return }
            val dayStart = java.time.LocalDate.parse(today).atStartOfDay(zone).toInstant().toEpochMilli()
            if (ex.countSince(dayStart) >= DAILY_CAP) { skipped("daily cap ($DAILY_CAP) reached"); return }
            if (ex.open(p.id).isNotEmpty()) { skipped("previous run still open"); return }
            if (!TermuxBridge.installed(c)) { failed("Termux not installed"); return }
            if (!TermuxBridge.permitted(c)) { failed("Termux run-command permission missing"); return }
            if (!Importer.sharedAccess()) { failed("All-files access missing"); return }
            val bd = db.batches(); val files = bd.filesNow(p.id)
            val plan = bd.batchesNow(p.id).map { b -> PlanBatch(b.seq, b.message, files.filter { it.batchId == b.id }.map { it.path }) }
            if (plan.none { it.files.isNotEmpty() }) { skipped("no batches"); return }
            TermuxBridge.writePlan(c, p.name, buildPlan(p.name, p.repoUrl, p.branch, plan))
            val req = newRequestId()
            ex.insert(ExecutionEntity(projectId = p.id, taskId = "", requestId = req, state = "PENDING", startedAt = now))
            TermuxBridge.send(c, listOf("bridge", req, "run", p.name, "--sync"))?.let { err ->
                ex.byRequest(req)?.let {
                    ex.update(it.copy(state = "FAILED", reason = err, finishedAt = System.currentTimeMillis()))
                    noteFor("PENDING", "FAILED", p.name, err, null, 0, false, System.currentTimeMillis(), System.currentTimeMillis())?.let { n -> Notify.post(c, it.id, n) }
                }
            }
        } finally {
            db.schedules().byId(id)?.let { arm(c, it) }
        }
    }

    /** Boot / time / timezone change / app update: re-arm everything and apply run-now to slots missed today. */
    suspend fun restore(c: Context) {
        val db = (c.applicationContext as GitDripApp).db; val now = System.currentTimeMillis()
        for (s in db.schedules().enabled()) {
            if (s.policy == "run-now" && isMissed(now, s.time, zoneOf(s.zone), s.days, s.lastFireDay)) fire(c, s.id, catchUp = true)
            else arm(c, s, now)
        }
    }
}
