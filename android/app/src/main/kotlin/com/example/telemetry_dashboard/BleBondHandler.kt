package com.example.telemetry_dashboard

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bonding for the BLE vehicle link (flutter_reactive_ble has no bonding
 * API). The ESP32 requires an encrypted, authenticated link, so the app pairs
 * explicitly from Config instead of letting the reconnect loop raise system
 * dialogs. All calls need BLUETOOTH_CONNECT on Android 12+; the Dart side
 * requests it first and SecurityException is reported as an error.
 */
class BleBondHandler(private val context: Context) : MethodChannel.MethodCallHandler {
	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
		if (adapter == null) {
			result.error("unsupported", "Bluetooth adapter unavailable", null)
			return
		}
		try {
			when (call.method) {
				"bondedDevices" -> {
					result.success(
						adapter.bondedDevices.map { mapOf("id" to it.address, "name" to (it.name ?: "")) },
					)
				}

				"bondState", "createBond", "removeBond" -> {
					val id = call.argument<String>("id")
					if (id.isNullOrEmpty() || !android.bluetooth.BluetoothAdapter.checkBluetoothAddress(id)) {
						result.error("bad_id", "Invalid Bluetooth address: $id", null)
						return
					}
					val device = adapter.getRemoteDevice(id)
					when (call.method) {
						"bondState" -> result.success(bondStateName(device.bondState))
						"createBond" -> result.success(device.bondState == BluetoothDevice.BOND_BONDED || device.createBond())
						else -> result.success(removeBond(device))
					}
				}

				else -> result.notImplemented()
			}
		} catch (e: SecurityException) {
			result.error("permission", e.message, null)
		}
	}

	private fun bondStateName(state: Int): String = when (state) {
		BluetoothDevice.BOND_BONDED -> "bonded"
		BluetoothDevice.BOND_BONDING -> "bonding"
		BluetoothDevice.BOND_NONE -> "none"
		else -> "unknown"
	}

	// removeBond is not public SDK API; if the platform blocks it the Dart
	// side tells the user to forget the device in Android settings.
	private fun removeBond(device: BluetoothDevice): Boolean {
		if (device.bondState == BluetoothDevice.BOND_NONE) {
			return true
		}
		return try {
			device.javaClass.getMethod("removeBond").invoke(device) as? Boolean ?: false
		} catch (e: Exception) {
			false
		}
	}
}
