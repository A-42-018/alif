package com.gitdrip.app.data

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** Notification plumbing (P16b). No secrets ever go in here: text is redacted and comes from result files only. */
object Notify {
    const val CH_FAIL = "failures"
    const val CH_OK = "results"
    private const val PREFS = "gitdrip_prefs"
    private const val K_SUCCESS = "notify_success"

    fun successEnabled(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(K_SUCCESS, false)
    fun setSuccess(c: Context, on: Boolean) { c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(K_SUCCESS, on).apply() }

    fun granted(c: Context) =
        Build.VERSION.SDK_INT < 33 || c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun nm(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannels(c: Context) {
        nm(c).createNotificationChannels(listOf(
            NotificationChannel(CH_FAIL, "Failed runs", NotificationManager.IMPORTANCE_HIGH).apply { description = "A scheduled commit could not be pushed" },
            NotificationChannel(CH_OK, "Successful pushes", NotificationManager.IMPORTANCE_LOW).apply { description = "A batch was committed and pushed" },
        ))
    }

    /** Silently does nothing when the permission is missing. [id] = execution row id, so a re-delivery replaces instead of stacking. */
    fun post(c: Context, id: Long, n: NoteSpec) {
        if (!granted(c)) return
        try {
            ensureChannels(c)
            val open = c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
                PendingIntent.getActivity(c, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            val b = Notification.Builder(c, if (n.failure) CH_FAIL else CH_OK)
                .setSmallIcon(if (n.failure) android.R.drawable.stat_notify_error else android.R.drawable.stat_sys_upload_done)
                .setContentTitle(n.title).setContentText(n.text).setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
            if (open != null) b.setContentIntent(open)
            nm(c).notify(id.toInt(), b.build())
        } catch (_: Exception) { /* a notification must never break a run */ }
    }
}
