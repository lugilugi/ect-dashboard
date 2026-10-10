import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/ingest/ble_nus_transport.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/command_dictionary_service.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';
import 'package:telemetry_dashboard/services/ingest/usb_service.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';

class _FakeTransport extends IngestTransport {
  _FakeTransport(
    this.mode, {
    required super.debugLog,
    required super.onBytes,
    required super.onDisconnected,
  });

  final LinkMode mode;
  final List<String> writes = <String>[];
  bool _open = false;
  bool closed = false;

  @override
  String get sourceLabel => mode.name;

  @override
  bool get isOpen => _open;

  @override
  Future<bool> tryConnect() async {
    _open = true;
    return true;
  }

  @override
  void write(Uint8List bytes) => writes.add(String.fromCharCodes(bytes));

  @override
  Future<void> close() async {
    _open = false;
    closed = true;
  }

  @override
  Future<List<UsbPortOption>> listOptions() async => const [];

  void emit(String text) => onBytes(Uint8List.fromList(text.codeUnits));

  void drop(String reason) {
    _open = false;
    onDisconnected(reason);
  }
}

class _Harness {
  _Harness({
    LinkMode mode = LinkMode.usb,
    CanTxService? Function(_Harness)? tx,
  }) {
    state.bleLinkSupported = true;
    state.updateLinkMode(mode);
    canTx = tx?.call(this);
    service = UsbService(
      state,
      TelemetryRecorder(state),
      GpsSourceManager(state),
      canTxService: canTx,
      transportFactory:
          (
            mode, {
            required debugLog,
            required onBytes,
            required onDisconnected,
          }) {
            final transport = _FakeTransport(
              mode,
              debugLog: debugLog,
              onBytes: onBytes,
              onDisconnected: onDisconnected,
            );
            transports.add(transport);
            return transport;
          },
    );
    state.onLinkModeChanged = service.applyLinkMode;
  }

  final DashboardState state = DashboardState();
  final List<_FakeTransport> transports = <_FakeTransport>[];
  late final UsbService service;
  CanTxService? canTx;

  _FakeTransport get active => transports.last;

  Future<void> start() async {
    service.start();
    await _settle();
  }

  void dispose() {
    service.stop();
    canTx?.dispose();
    state.dispose();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _crc16Hex(String value) {
  int crc = 0xFFFF;
  for (final byte in value.codeUnits) {
    crc ^= (byte & 0xFF) << 8;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc.toRadixString(16).padLeft(4, '0').toUpperCase();
}

const String _stream =
    'can0 110#004004000000\n'
    'can0 310#000f2c01\n'
    'can0 400#e803a08601000101\n';

void main() {
  group('UsbService link pipeline', () {
    test(
      'split and coalesced chunks decode identically on USB and BLE',
      () async {
        final results = <LinkMode, Map<int, String>>{};
        for (final mode in LinkMode.values) {
          for (final chunkSize in [1, 7, 20, _stream.length]) {
            final harness = _Harness(mode: mode);
            addTearDown(harness.dispose);
            await harness.start();
            expect(harness.state.isConnected, isTrue);

            for (var i = 0; i < _stream.length; i += chunkSize) {
              final end = (i + chunkSize).clamp(0, _stream.length);
              harness.active.emit(_stream.substring(i, end));
            }

            final payloads = Map<int, String>.of(harness.state.lastCanPayloads);
            expect(payloads.keys, containsAll(<int>[0x110, 0x310, 0x400]));
            expect(harness.state.canLog.map((e) => e.source).toSet(), {
              mode.name,
            });
            results[mode] ??= payloads;
            expect(payloads, results[mode]);
          }
        }
        expect(results[LinkMode.ble], results[LinkMode.usb]);
      },
    );

    test('commands go out on the active link and acks resolve them', () async {
      final harness = _Harness(
        mode: LinkMode.ble,
        tx: (h) => CanTxService(
          dictionaryService: CommandDictionaryService(),
          sendRawFrame: (frame) => h.service.sendString(frame),
          ackTimeout: const Duration(seconds: 2),
        ),
      );
      addTearDown(harness.dispose);
      await harness.start();

      final future = harness.canTx!.sendCommand(
        TxCanCommand(
          commandKey: 'LEFT_TURN_TOGGLE',
          args: const <int>[],
          targetCanId: CommandDictionaryService.auxControlCanId,
          issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
          source: 'test',
          safetyTag: CanTxSafetyClass.operational,
        ),
      );
      expect(harness.active.writes.single, startsWith('C|v1|1|10|'));
      expect(harness.active.writes.single, endsWith('\n'));

      // A BLE notification can split the ack anywhere.
      const ackBody = 'A|v1|1|ok|none';
      final ack = '$ackBody|${_crc16Hex(ackBody)}\n';
      harness.active.emit(ack.substring(0, 9));
      harness.active.emit(ack.substring(9));

      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.status, TxCommandStatus.acked);
    });

    test(
      'switching link mode closes the old link and drops its partial line',
      () async {
        final harness = _Harness(mode: LinkMode.usb);
        addTearDown(harness.dispose);
        await harness.start();
        final usb = harness.active;

        usb.emit('can0 31');
        harness.state.updateLinkMode(LinkMode.ble);
        await _settle();

        expect(usb.closed, isTrue);
        final ble = harness.active;
        expect(ble, isNot(same(usb)));
        expect(ble.mode, LinkMode.ble);
        expect(harness.state.isConnected, isTrue);

        // The tail of the USB line must not join BLE bytes into a frame.
        ble.emit('0#000f2c01\ncan0 110#004004000000\n');
        expect(harness.state.lastCanPayloads.containsKey(0x310), isFalse);
        expect(harness.state.lastCanPayloads.containsKey(0x110), isTrue);
      },
    );

    test('link loss clears the connection and logs the reason', () async {
      final harness = _Harness(mode: LinkMode.ble);
      addTearDown(harness.dispose);
      await harness.start();

      harness.active.emit('can0 31');
      harness.active.drop('BLE device disconnected (test)');

      expect(harness.state.isConnected, isFalse);
      expect(
        harness.service.debugLog.entries.map((e) => e.message),
        contains('BLE device disconnected (test)'),
      );
    });
  });

  group('chunkForMtu', () {
    test('keeps order and fits the ATT payload', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(600, (i) => i & 0xFF),
      );
      for (final mtu in [23, 185, 247, 517]) {
        final chunks = chunkForMtu(bytes, mtu);
        for (final chunk in chunks) {
          expect(chunk.length, lessThanOrEqualTo(mtu - 3));
        }
        expect(chunks.expand((c) => c).toList(), bytes);
      }
      expect(chunkForMtu(Uint8List(0), 247), isEmpty);
    });
  });
}
