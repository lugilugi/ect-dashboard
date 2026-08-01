package com.example.telemetry_dashboard

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator

/**
 * Plays driver alert cues on Android.
 *
 * Flutter's SystemSound API is a no-op on Android, so audio cues are generated
 * with a ToneGenerator on STREAM_ALARM; haptics use the system Vibrator with
 * severity-specific patterns. Requires android.permission.VIBRATE.
 */
object AlertCuePlayer {
    private val handler = Handler(Looper.getMainLooper())

    fun playAudio(context: Context, severity: String, volume: Double) {
        val tone = when (severity) {
            "ADVISORY" -> ToneGenerator.TONE_PROP_BEEP to 150
            "CRITICAL" -> ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD to 700
            else -> ToneGenerator.TONE_CDMA_ALERT_NETWORK_LITE to 350
        }
        val generator = ToneGenerator(
            AudioManager.STREAM_ALARM,
            (volume * 100).toInt().coerceIn(10, 100),
        )
        generator.startTone(tone.first, tone.second)
        handler.postDelayed({ generator.release() }, (tone.second + 150).toLong())
    }

    fun playHaptic(context: Context, severity: String) {
        val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        val pattern = when (severity) {
            "ADVISORY" -> longArrayOf(0, 40)
            "CRITICAL" -> longArrayOf(0, 120, 60, 120, 60, 120)
            else -> longArrayOf(0, 80, 40, 80)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
        }
    }
}
