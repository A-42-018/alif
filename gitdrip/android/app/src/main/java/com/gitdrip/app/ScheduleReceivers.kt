package com.gitdrip.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.gitdrip.app.data.Scheduler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

private fun BroadcastReceiver.async(block: suspend () -> Unit) {
    val r = goAsync()
    CoroutineScope(Dispatchers.IO).launch { try { block() } catch (_: Exception) { } finally { r.finish() } }
}

/** Exact alarm -> run next batch for that schedule. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        if (i.action != Scheduler.ACTION_FIRE) return
        val id = i.getLongExtra(Scheduler.EXTRA_ID, -1L); if (id < 0) return
        async { Scheduler.fire(c.applicationContext, id) }
    }
}

/** Boot, package update, clock / timezone change: alarms are lost or shifted, so re-arm (+ run-now catch-up). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        when (i.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_TIME_CHANGED -> async { Scheduler.restore(c.applicationContext) }
        }
    }
}
