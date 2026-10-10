# BLE vehicle link (ESP32-C3 firmware contract)

The Android app can talk to the vehicle ESP32-C3 over Bluetooth LE instead of
USB. The user picks the transport in Config -> Connectivity -> VEHICLE LINK
(USB | BLE). BLE is Android-only; desktop builds keep USB serial.

BLE is a different pipe for the **same bytes**. Everything above the byte
stream is unchanged: candump line framing, CAN decode via the DBC, command
frames and acks, and the telemetry contract
([telemetry-v2.md](../contracts/telemetry-v2.md)). Telemetry events keep
`source: "can"`; only the debug CAN log shows `ble` as the ingest label.

## GATT service

Nordic UART Service (NUS). TX/RX are named from the ESP32's side.

| Role | UUID | Properties | Permissions |
|---|---|---|---|
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | | |
| RX (phone -> ESP32) | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | Write Without Response (+ Write) | encrypted + authenticated |
| TX (ESP32 -> phone) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | Notify | CCCD write encrypted + authenticated |

- Advertise the NUS service UUID. Name: `EcoArchers-<id>`. The app also
  accepts the name prefix alone (`--dart-define=BLE_NAME_PREFIX=...`).
- Accept one central at a time.

## Security

The link carries vehicle commands, so it must not work unpaired.

- LE Secure Connections with MITM protection and bonding.
- IO capability DisplayOnly with a fixed 6-digit passkey. The team enters it
  once on the phone (Config -> PAIR); Android then stores the bond.
- RX writes and TX CCCD writes are rejected on an unencrypted or
  unauthenticated link. An unbonded phone must not be able to read or write.
- Keep bonds in NVS so a power cycle does not force re-pairing.

## Link parameters

- Preferred ATT MTU 247. The app requests 247 and chunks its writes to
  MTU-3. It also works at the default 23, just more slowly.
- Accept the app's high-priority connection request (7.5–15 ms interval).
  2M PHY is welcome but not required.

## Payload

Byte-identical to what the firmware writes to USB CDC:

- ESP32 -> phone: `can0 <ID hex>#<payload hex>\n` per CAN frame, and
  `A|v1|<seq>|<ok|...>|<err>|<CRC16>\n` command acks.
- Phone -> ESP32: `C|v1|<seq>|<cmd>|<args...>|<CRC16>\n` commands and legacy
  `CMD:...\n` lines. One line can span several writes; reassemble on `\n`.

Batching rules for notifications:

- Pack whole lines into each notification, up to MTU-3 bytes. Splitting a
  line across notifications is allowed (the app reassembles), but avoid it.
- Flush at least every 20 ms even if the packet is not full. The app stamps
  `receivedAtUtc` on arrival, so batching delay adds directly to timestamp
  skew.
- Budget: about 250 frames/s at ~26 bytes per line is ~6.5 KB/s, well below
  NUS throughput at MTU 247.
- If the notify queue backs up, drop the oldest lines and count the drops.
  Never block the CAN receive task.

Commands:

- The app waits 350 ms for an ack, then resends the **same** `seq` up to two
  times. De-duplicate by `seq` so a retry never executes a command twice; ack
  the duplicate again.

## Coexistence

USB CDC output keeps working while BLE is connected, so switching the app
back to USB needs no firmware change.

## App behavior (for reference)

- Reconnect: every 3 s the app connects directly to the selected, bonded
  device. It never scans in the background (Android throttles apps that start
  more than five scans per 30 s); scanning only happens from the Config scan
  button.
- An unbonded or unselected device is not connected; the debug log says why.
- UNPAIR removes the Android bond. If Android blocks that, forget the device
  in Android Bluetooth settings.

Hardware qualification gates for this link are tracked in
[verification.md](verification.md#ble-vehicle-link).
