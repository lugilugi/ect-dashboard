package com.example.telemetry_dashboard

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.EventChannel

class FusedLocationStreamHandler(
    private val context: Context,
) : EventChannel.StreamHandler {
    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)

    private var eventSink: EventChannel.EventSink? = null
    private var locationCallback: LocationCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        startLocationUpdates()
    }

    override fun onCancel(arguments: Any?) {
        stopLocationUpdates()
        eventSink = null
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

        val coarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

        return fine || coarse
    }

    @SuppressLint("MissingPermission")
    private fun startLocationUpdates() {
        if (!hasLocationPermission()) {
            eventSink?.error(
                "missing_permission",
                "Location permission is not granted.",
                null,
            )
            return
        }

        if (locationCallback != null) {
            return
        }

        val locationRequest = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            REQUEST_INTERVAL_MS,
        ).setMinUpdateIntervalMillis(MIN_UPDATE_INTERVAL_MS)
            .setMaxUpdateDelayMillis(MAX_UPDATE_DELAY_MS)
            .setWaitForAccurateLocation(true)
            .build()

        val callback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                for (location in locationResult.locations) {
                    val payload = hashMapOf<String, Any>(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "accuracyM" to location.accuracy.toDouble(),
                        "speedMps" to if (location.hasSpeed()) {
                            location.speed.toDouble()
                        } else {
                            0.0
                        },
                        "headingDeg" to if (location.hasBearing()) {
                            location.bearing.toDouble()
                        } else {
                            0.0
                        },
                        "timestampMs" to location.time,
                        "provider" to (location.provider ?: "fused"),
                    )
                    eventSink?.success(payload)
                }
            }

            override fun onLocationAvailability(locationAvailability: LocationAvailability) {
                eventSink?.success(
                    hashMapOf(
                        "available" to locationAvailability.isLocationAvailable,
                    ),
                )
            }
        }

        try {
            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                callback,
                Looper.getMainLooper(),
            )
            locationCallback = callback
        } catch (securityException: SecurityException) {
            eventSink?.error(
                "security_exception",
                securityException.message,
                null,
            )
            locationCallback = null
        }
    }

    private fun stopLocationUpdates() {
        val callback = locationCallback ?: return
        fusedLocationClient.removeLocationUpdates(callback)
        locationCallback = null
    }

    companion object {
        private const val REQUEST_INTERVAL_MS = 33L
        private const val MIN_UPDATE_INTERVAL_MS = 33L
        private const val MAX_UPDATE_DELAY_MS = 66L
    }
}