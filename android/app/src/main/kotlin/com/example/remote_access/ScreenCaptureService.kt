package com.example.remote_access

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service required for MediaProjection screen capture on Android
 * 10+ (and mandatory, typed `mediaProjection`, on Android 14+). flutter_webrtc
 * does not provide one, so the app must run this while a session is active.
 * Started/stopped from MainActivity via the `remote_access/capture` channel.
 *
 * On Android 14+ `startForeground(... TYPE_MEDIA_PROJECTION)` throws a
 * SecurityException unless the `project_media` app-op has been granted — by the
 * MediaProjection consent dialog, or pre-granted by an MDM/Device-Owner for
 * unattended kiosks. We MUST catch that here: an uncaught throwable in
 * onStartCommand kills the whole process ("remote_access has stopped"). Instead
 * we report the failure back so the session can be aborted with a clear message.
 */
class ScreenCaptureService : Service() {

    companion object {
        private const val TAG = "ScreenCaptureService"
        private const val CHANNEL_ID = "remote_access_capture"
        private const val NOTIFICATION_ID = 7341

        /**
         * Invoked once, on the next onStartCommand, with (started, errorMessage).
         * MainActivity sets this before calling startForegroundService so it can
         * report the real outcome back to Flutter instead of leaving a hung
         * Future / a process that silently fails to capture.
         */
        @Volatile
        var startResultCallback: ((Boolean, String?) -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()

        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Remote support active")
            .setContentText("Your screen is being shared with an administrator.")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()

        val error: String? = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            null
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to start mediaProjection foreground service", t)
            t.message ?: t.javaClass.simpleName
        }

        val callback = startResultCallback
        startResultCallback = null
        callback?.invoke(error == null, error)

        if (error != null) {
            // Could not enter the foreground as a mediaProjection service. Bail
            // out cleanly so we don't leave a half-started service (which would
            // otherwise trip the "did not start in time" watchdog).
            stopSelf()
            return START_NOT_STICKY
        }

        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Remote support",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    override fun onDestroy() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
            // Already gone; nothing to tear down.
        }
        super.onDestroy()
    }
}
