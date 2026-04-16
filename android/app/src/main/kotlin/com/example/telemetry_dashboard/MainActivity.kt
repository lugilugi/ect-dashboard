package com.example.telemetry_dashboard

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		private const val FOREGROUND_CHANNEL = "ect_dashboard/foreground_telemetry"
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

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
