package com.example.telemetry_dashboard

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class TelemetryForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        return when (action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                START_NOT_STICKY
            }

            else -> {
                startAsForeground(intent)
                START_STICKY
            }
        }
    }

    private fun startAsForeground(intent: Intent?) {
        ensureChannel()

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "ECT Telemetry Active"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Session is active."

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = if (openIntent == null) {
            null
        } else {
            PendingIntent.getActivity(
                this,
                0,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        startForeground(NOTIFICATION_ID, builder.build())
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Keeps telemetry and GPS updates active during ARMED/LOGGING."
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "ect_telemetry_foreground"
        private const val CHANNEL_NAME = "Telemetry Runtime"
        private const val NOTIFICATION_ID = 12051

        private const val ACTION_START = "com.example.telemetry_dashboard.action.START"
        private const val ACTION_STOP = "com.example.telemetry_dashboard.action.STOP"
        private const val EXTRA_TITLE = "extra_title"
        private const val EXTRA_TEXT = "extra_text"

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, TelemetryForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, TelemetryForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }
}
