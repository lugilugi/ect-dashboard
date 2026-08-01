package com.example.telemetry_dashboard

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		private const val FOREGROUND_CHANNEL = "ect_dashboard/foreground_telemetry"
		private const val FUSED_LOCATION_CHANNEL = "ect_dashboard/fused_location"
		private const val ALERT_CUE_CHANNEL = "ect_dashboard/alert_cue"
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		EventChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			FUSED_LOCATION_CHANNEL,
		).setStreamHandler(FusedLocationStreamHandler(this))

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			ALERT_CUE_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"playAudio" -> {
					val severity = call.argument<String>("severity") ?: "WARNING"
					val volume = call.argument<Double>("volume") ?: 0.75
					val cue = call.argument<String>("cue") ?: "BEEP"
					AlertCuePlayer.playAudio(this, severity, volume, cue)
					result.success(null)
				}

				"playHaptic" -> {
					val severity = call.argument<String>("severity") ?: "WARNING"
					AlertCuePlayer.playHaptic(this, severity)
					result.success(null)
				}

				else -> result.notImplemented()
			}
		}

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			FOREGROUND_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"startForegroundTelemetry" -> {
					val title = call.argument<String>("title") ?: "ECT Telemetry Active"
					val text = call.argument<String>("text") ?: "Session is active."
					TelemetryForegroundService.start(this, title, text)
					result.success(null)
				}

				"stopForegroundTelemetry" -> {
					TelemetryForegroundService.stop(this)
					result.success(null)
				}

				else -> result.notImplemented()
			}
		}
	}
}
