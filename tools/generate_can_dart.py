#!/usr/bin/env python3
"""Generate the static Dart CAN database from the authoritative DBC.

The generated Dart is deliberately a wire-protocol module. Application
semantics, MQTT metric names, unit conversions, and DashboardState updates
belong in handwritten Dart bindings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
import cantools
from cantools.database.can import Database, Message, Signal


GENERATOR_VERSION = "1.0.0"


def dart_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def dart_float(value: float | int) -> str:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"non-finite numeric value is not supported: {value!r}")
    rendered = repr(number)
    if rendered == "-0.0":
        return "0.0"
    if "." not in rendered and "e" not in rendered.lower():
        rendered += ".0"
    return rendered


def dart_identifier(value: str, *, prefix: str = "") -> str:
    parts = [part.lower() for part in re.split(r"[^A-Za-z0-9]+", value) if part]
    if not parts:
        raise ValueError(f"cannot create a Dart identifier from {value!r}")
    identifier = parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])
    if not re.match(r"^[A-Za-z_]", identifier):
        identifier = "_" + identifier
    return prefix + identifier


def dart_type_name(value: str) -> str:
    parts = [part for part in re.split(r"[^A-Za-z0-9]+", value) if part]
    if not parts:
        raise ValueError(f"cannot create a Dart type name from {value!r}")
    return "".join(part[:1].upper() + part[1:].lower() for part in parts)


def validate_database(db: Database) -> None:
    seen_ids: set[int] = set()
    for message in db.messages:
        if message.frame_id in seen_ids:
            raise ValueError(
                f"duplicate frame id 0x{message.frame_id:X}; "
                "standard and extended identifiers need distinct generated dispatch"
            )
        seen_ids.add(message.frame_id)

        if message.is_fd:
            raise ValueError(
                f"CAN-FD message {message.name} is not supported by generator {GENERATOR_VERSION}"
            )

        for signal in message.signals:
            if signal.length < 1 or signal.length > 64:
                raise ValueError(
                    f"{message.name}.{signal.name}: signal length must be 1..64"
                )
            if getattr(signal, "is_multiplexer", False) or getattr(
                signal, "multiplexer_ids", None
            ):
                raise ValueError(
                    f"unsupported multiplexed signal {message.name}.{signal.name}; "
                    f"generator {GENERATOR_VERSION} does not support multiplexing"
                )
            if getattr(signal, "is_float", False):
                raise ValueError(
                    f"floating-point signal {message.name}.{signal.name} is not supported"
                )


def signal_choices(signal: Signal) -> str:
    choices = signal.choices or {}
    if not choices:
        return "<int, String>{}"
    entries = ", ".join(
        f"{int(raw)}: {dart_string(str(label))}" for raw, label in sorted(choices.items())
    )
    return f"<int, String>{{{entries}}}"


def render_signal_definition(signal: Signal) -> str:
    unit = "null" if signal.unit is None else dart_string(signal.unit)
    minimum = "null" if signal.minimum is None else dart_float(signal.minimum)
    maximum = "null" if signal.maximum is None else dart_float(signal.maximum)
    return """CanSignalDefinition(
      name: %s,
      startBit: %d,
      bitLength: %d,
      littleEndian: %s,
      signed: %s,
      factor: %s,
      offset: %s,
      unit: %s,
      minimum: %s,
      maximum: %s,
      choices: %s,
    )""" % (
        dart_string(signal.name),
        signal.start,
        signal.length,
        "true" if signal.byte_order == "little_endian" else "false",
        "true" if signal.is_signed else "false",
        dart_float(signal.scale),
        dart_float(signal.offset),
        unit,
        minimum,
        maximum,
        signal_choices(signal),
    )


def receivers_for(message: Message) -> list[str]:
    receivers: set[str] = set()
    for signal in message.signals:
        receivers.update(signal.receivers or [])
    return sorted(receivers)


def message_comment(message: Message) -> str | None:
    comment = message.comment
    return None if comment is None else str(comment)


def render_message_definition(message: Message, field_name: str) -> str:
    cycle_time = "null" if message.cycle_time is None else str(int(message.cycle_time))
    comment = message_comment(message)
    comment_literal = "null" if comment is None else dart_string(comment)
    senders = ", ".join(dart_string(str(sender)) for sender in message.senders)
    receivers = ", ".join(dart_string(receiver) for receiver in receivers_for(message))
    signals = ",\n".join(
        "        " + render_signal_definition(signal).replace("\n", "\n        ")
        for signal in message.signals
    )
    return """  static const CanMessageDefinition %s = CanMessageDefinition(
    canId: 0x%X,
    name: %s,
    length: %d,
    isExtendedFrame: %s,
    cycleTimeMs: %s,
    senders: <%s>[%s],
    receivers: <%s>[%s],
    comment: %s,
    signals: <CanSignalDefinition>[
%s
    ],
  );""" % (
        field_name,
        message.frame_id,
        dart_string(message.name),
        message.length,
        "true" if message.is_extended_frame else "false",
        cycle_time,
        "String",
        senders,
        "String",
        receivers,
        comment_literal,
        signals,
    )


def render_decoder(message: Message, field_name: str, function_name: str) -> str:
    signal_entries = []
    for index, signal in enumerate(message.signals):
        signal_entries.append(
            "      %s: _decodeSignal(data, %s.signals[%d]),"
            % (dart_string(signal.name), field_name, index)
        )
    return """  static DecodedCanMessage %s(Uint8List data) {
    _requireLength(data, %s);
    return DecodedCanMessage(
      definition: %s,
      signals: <String, double>{
%s
      },
    );
  }
""" % (function_name, field_name, field_name, "\n".join(signal_entries))


def render_database(db: Database, dbc_path: Path) -> str:
    raw_dbc = dbc_path.read_bytes()
    canonical_dbc = raw_dbc.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    dbc_hash = hashlib.sha256(canonical_dbc).hexdigest()
    version = db.version or "unknown"
    messages = sorted(db.messages, key=lambda message: message.frame_id)

    names: dict[str, int] = {}
    fields: list[tuple[Message, str, str]] = []
    for message in messages:
        field_name = dart_identifier(message.name)
        if field_name in names:
            raise ValueError(
                f"message names {messages[names[field_name]].name!r} and "
                f"{message.name!r} collide as Dart identifiers"
            )
        names[field_name] = len(fields)
        fields.append(
            (message, field_name, f"_decode{dart_type_name(message.name)}")
        )

    id_constants = "\n".join(
        f"  static const int {field_name} = 0x{message.frame_id:X};"
        for message, field_name, _ in fields
    )
    definitions = "\n\n".join(
        render_message_definition(message, field_name)
        for message, field_name, _ in fields
    )
    dispatch_cases = "\n".join(
        f"      case 0x{message.frame_id:X}:\n"
        f"        return {function_name}(data);"
        for message, _, function_name in fields
    )
    decoders = "\n".join(
        render_decoder(message, field_name, function_name)
        for message, field_name, function_name in fields
    )
    message_list = ",\n".join(f"    {field_name}" for _, field_name, _ in fields)
    lookup = ",\n".join(
        f"    0x{message.frame_id:X}: {field_name}"
        for message, field_name, _ in fields
    )

    return f'''// GENERATED FILE - DO NOT EDIT.
// Generated by tools/generate_can_dart.py {GENERATOR_VERSION}.
// DBC VERSION: {version}
// DBC SHA-256 (LF-normalized): {dbc_hash}
// cantools: {cantools.__version__}

import 'dart:typed_data';

class CanDecodeException implements Exception {{
  final String message;

  const CanDecodeException(this.message);

  @override
  String toString() => 'CanDecodeException: $message';
}}

class CanSignalDefinition {{
  final String name;
  final int startBit;
  final int bitLength;
  final bool littleEndian;
  final bool signed;
  final double factor;
  final double offset;
  final String? unit;
  final double? minimum;
  final double? maximum;
  final Map<int, String> choices;

  const CanSignalDefinition({{
    required this.name,
    required this.startBit,
    required this.bitLength,
    required this.littleEndian,
    required this.signed,
    required this.factor,
    required this.offset,
    required this.unit,
    required this.minimum,
    required this.maximum,
    required this.choices,
  }});

  String? choiceForRaw(int rawValue) => choices[rawValue];
}}

class CanMessageDefinition {{
  final int canId;
  final String name;
  final int length;
  final bool isExtendedFrame;
  final int? cycleTimeMs;
  final List<String> senders;
  final List<String> receivers;
  final String? comment;
  final List<CanSignalDefinition> signals;

  const CanMessageDefinition({{
    required this.canId,
    required this.name,
    required this.length,
    required this.isExtendedFrame,
    required this.cycleTimeMs,
    required this.senders,
    required this.receivers,
    required this.comment,
    required this.signals,
  }});

  CanSignalDefinition signalByName(String signalName) {{
    for (final signal in signals) {{
      if (signal.name == signalName) {{
        return signal;
      }}
    }}
    throw ArgumentError.value(signalName, 'signalName', 'unknown signal');
  }}
}}

class DecodedCanMessage {{
  final CanMessageDefinition definition;
  final Map<String, double> signals;

  DecodedCanMessage({{
    required this.definition,
    required Map<String, double> signals,
  }}) : signals = Map<String, double>.unmodifiable(signals);

  int get canId => definition.canId;
  String get messageName => definition.name;

  double value(String signalName) {{
    final value = signals[signalName];
    if (value == null) {{
      throw ArgumentError.value(signalName, 'signalName', 'unknown signal');
    }}
    return value;
  }}
}}

abstract final class CanIds {{
{id_constants}
}}

abstract final class CanDatabase {{
  static const String version = {dart_string(version)};
  static const String sha256 = {dart_string(dbc_hash)};
  static const String generatorVersion = {dart_string(GENERATOR_VERSION)};

{definitions}

  static const List<CanMessageDefinition> messages = <CanMessageDefinition>[
{message_list}
  ];

  static final Map<int, CanMessageDefinition> _messagesById = <int, CanMessageDefinition>{{
{lookup}
  }};

  static CanMessageDefinition? messageById(int canId) => _messagesById[canId];

  static DecodedCanMessage? decode(int canId, Uint8List data) {{
    switch (canId) {{
{dispatch_cases}
      default:
        return null;
    }}
  }}

{decoders}
  static double _decodeSignal(
    Uint8List data,
    CanSignalDefinition signal,
  ) {{
    final raw = _extractRaw(data, signal);
    return raw.toDouble() * signal.factor + signal.offset;
  }}

  static int _extractRaw(
    Uint8List data,
    CanSignalDefinition signal,
  ) {{
    var raw = 0;
    if (signal.littleEndian) {{
      for (var offset = 0; offset < signal.bitLength; offset += 1) {{
        final bitIndex = signal.startBit + offset;
        final bit = (data[bitIndex ~/ 8] >> (bitIndex % 8)) & 1;
        raw |= bit << offset;
      }}
    }} else {{
      var bitIndex = signal.startBit;
      for (var offset = 0; offset < signal.bitLength; offset += 1) {{
        final bit = (data[bitIndex ~/ 8] >> (bitIndex % 8)) & 1;
        raw |= bit << (signal.bitLength - offset - 1);
        final bitInByte = bitIndex % 8;
        bitIndex = bitInByte == 0 ? bitIndex + 15 : bitIndex - 1;
      }}
    }}

    if (signal.signed &&
        (raw & (1 << (signal.bitLength - 1))) != 0) {{
      raw -= 1 << signal.bitLength;
    }}
    return raw;
  }}

  static void _requireLength(
    Uint8List data,
    CanMessageDefinition definition,
  ) {{
    if (data.length != definition.length) {{
      throw CanDecodeException(
        '${{definition.name}} requires DLC ${{definition.length}}, got ${{data.length}}',
      );
    }}
  }}
}}
'''


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dbc', type=Path, default=root / 'dbc' / 'network.dbc')
    parser.add_argument(
        '--output',
        type=Path,
        default=root / 'lib' / 'models' / 'telemetry' / 'generated' / 'can_database.g.dart',
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    dbc_path = args.dbc.resolve()
    output_path = args.output.resolve()
    db = cantools.database.load_file(str(dbc_path), database_format='dbc')
    validate_database(db)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_database(db, dbc_path), encoding='utf-8', newline='\n')
    print(
        f'Generated {output_path} from {dbc_path} '
        f'({len(db.messages)} messages, DBC {db.version or "unknown"}).'
    )


if __name__ == '__main__':
    main()
