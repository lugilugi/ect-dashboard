package com.example.telemetry_dashboard

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
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
    private var gnssStatusCallback: GnssStatus.Callback? = null
    private var lastSatellitesUsed = -1

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

        registerGnssStatusListener()

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
                        "satellites" to lastSatellitesUsed,
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
        unregisterGnssStatusListener()
    }

    @SuppressLint("MissingPermission")
    private fun registerGnssStatusListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return
        }

        val locationManager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return

        if (gnssStatusCallback != null) {
            return
        }

        val callback = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                var usedInFix = 0
                for (index in 0 until status.satelliteCount) {
                    if (status.usedInFix(index)) {
                        usedInFix++
                    }
                }
                lastSatellitesUsed = usedInFix
            }
        }

        try {
            locationManager.registerGnssStatusCallback(callback)
            gnssStatusCallback = callback
        } catch (securityException: SecurityException) {
            debugPrint("GNSS status callback registration failed: $securityException")
            gnssStatusCallback = null
        }
    }

    private fun unregisterGnssStatusListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return
        }

        val callback = gnssStatusCallback ?: return
        val locationManager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return
        locationManager.unregisterGnssStatusCallback(callback)
        gnssStatusCallback = null
    }

    private fun debugPrint(message: String) {
        android.util.Log.d("FusedLocationStreamHandler", message)
    }

    companion object {
        private const val REQUEST_INTERVAL_MS = 33L
        private const val MIN_UPDATE_INTERVAL_MS = 33L
        private const val MAX_UPDATE_DELAY_MS = 66L
    }
}