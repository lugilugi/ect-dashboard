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
 *
 * Each cue is a distinct tone sequence so the driver can tell which parameter
 * is alarming by sound alone. Sequences are scheduled with the main handler.
 */
object AlertCuePlayer {
    private val handler = Handler(Looper.getMainLooper())

    data class ToneSequence(val tones: List<Pair<Int, Int>>)

    private val cueTones: Map<String, ToneSequence> = mapOf(
        // (tone, durationMs) pairs, played back to back
        "BEEP" to ToneSequence(
            listOf(ToneGenerator.TONE_PROP_BEEP to 150),
        ),
        "DOUBLE_BEEP" to ToneSequence(
            listOf(
                ToneGenerator.TONE_PROP_BEEP to 120,
                ToneGenerator.TONE_PROP_BEEP to 120,
            ),
        ),
        "TRIPLE_BEEP" to ToneSequence(
            listOf(
                ToneGenerator.TONE_PROP_BEEP to 100,
                ToneGenerator.TONE_PROP_BEEP to 100,
                ToneGenerator.TONE_PROP_BEEP to 100,
            ),
        ),
        "LONG_BEEP" to ToneSequence(
            listOf(ToneGenerator.TONE_CDMA_ALERT_NETWORK_LITE to 800),
        ),
        "SIREN" to ToneSequence(
            listOf(
                ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD to 300,
                ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD to 300,
                ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD to 300,
            ),
        ),
    )

    fun playAudio(context: Context, severity: String, volume: Double, cue: String) {
        val sequence = cueTones[cue] ?: cueTones.getValue("BEEP")
        val generator = ToneGenerator(
            AudioManager.STREAM_ALARM,
            (volume * 100).toInt().coerceIn(10, 100),
        )

        var offset = 0L
        for ((tone, duration) in sequence.tones) {
            handler.postDelayed({
                try {
                    generator.startTone(tone, duration)
                } catch (_: Exception) {
                    // ToneGenerator may be released between scheduled cues.
                }
            }, offset)
            offset += duration + 120L
        }
        handler.postDelayed({ generator.release() }, offset + 150L)
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
