enum DriverAlertSeverity {
  advisory,
  warning,
  critical,
}

extension DriverAlertSeverityWire on DriverAlertSeverity {
  String get wireValue {
    switch (this) {
      case DriverAlertSeverity.advisory:
        return 'ADVISORY';
      case DriverAlertSeverity.warning:
        return 'WARNING';
      case DriverAlertSeverity.critical:
        return 'CRITICAL';
    }
  }

  String get shortLabel {
    switch (this) {
      case DriverAlertSeverity.advisory:
        return 'ADV';
      case DriverAlertSeverity.warning:
        return 'WARN';
      case DriverAlertSeverity.critical:
        return 'CRIT';
    }
  }
}

/// CAN-derived variables that can trigger driver alerts.
enum AlertVariableKey {
  voltage,
  current,
  power,
  speed,
  mcTemp,
  battTemp,
  bmsMinCell,
  bus12V,
}

extension AlertVariableKeyWire on AlertVariableKey {
  String get wireValue {
    switch (this) {
      case AlertVariableKey.voltage:
        return 'VOLTAGE';
      case AlertVariableKey.current:
        return 'CURRENT';
      case AlertVariableKey.power:
        return 'POWER';
      case AlertVariableKey.speed:
        return 'SPEED';
      case AlertVariableKey.mcTemp:
        return 'MC_TEMP';
      case AlertVariableKey.battTemp:
        return 'BATT_TEMP';
      case AlertVariableKey.bmsMinCell:
        return 'BMS_MIN_CELL';
      case AlertVariableKey.bus12V:
        return 'BUS_12V';
    }
  }
}

AlertVariableKey? alertVariableKeyFromWire(String value) {
  for (final key in AlertVariableKey.values) {
    if (key.wireValue == value) {
      return key;
    }
  }
  return null;
}

class AlertVariableSpec {
  final AlertVariableKey key;
  final String label;
  final String unit;
  final double defaultMin;
  final double defaultMax;
  final DriverAlertSeverity severity;
  final int fractionDigits;
  final bool defaultEnabled;

  /// The car-off default the dashboard holds before CAN data flows.
  /// While a variable still reads this exact value it has no live data,
  /// so threshold evaluation is skipped to avoid startup false alarms.
  final double restValue;

  const AlertVariableSpec({
    required this.key,
    required this.label,
    required this.unit,
    required this.defaultMin,
    required this.defaultMax,
    required this.severity,
    required this.restValue,
    this.fractionDigits = 1,
    this.defaultEnabled = true,
  });
}

const List<AlertVariableSpec> alertVariableSpecs = <AlertVariableSpec>[
  AlertVariableSpec(
    key: AlertVariableKey.voltage,
    label: 'MAIN VOLTAGE',
    unit: 'V',
    defaultMin: 30,
    defaultMax: 60,
    severity: DriverAlertSeverity.warning,
    restValue: 0,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.current,
    label: 'MOTOR CURRENT',
    unit: 'A',
    defaultMin: 0,
    defaultMax: 60,
    severity: DriverAlertSeverity.warning,
    restValue: 0,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.power,
    label: 'POWER',
    unit: 'W',
    defaultMin: 0,
    defaultMax: 3000,
    severity: DriverAlertSeverity.critical,
    fractionDigits: 0,
    restValue: 0,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.speed,
    label: 'SPEED',
    unit: 'km/h',
    defaultMin: 0,
    defaultMax: 55,
    severity: DriverAlertSeverity.advisory,
    defaultEnabled: false,
    restValue: 0,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.mcTemp,
    label: 'M.C. TEMP',
    unit: '°C',
    defaultMin: 0,
    defaultMax: 85,
    severity: DriverAlertSeverity.critical,
    fractionDigits: 0,
    restValue: 45,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.battTemp,
    label: 'BATT TEMP',
    unit: '°C',
    defaultMin: 0,
    defaultMax: 55,
    severity: DriverAlertSeverity.critical,
    fractionDigits: 0,
    restValue: 35,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.bmsMinCell,
    label: 'BMS MIN CELL',
    unit: 'V',
    defaultMin: 3.0,
    defaultMax: 4.3,
    severity: DriverAlertSeverity.critical,
    fractionDigits: 2,
    restValue: 3.80,
  ),
  AlertVariableSpec(
    key: AlertVariableKey.bus12V,
    label: 'BUS 12V',
    unit: 'V',
    defaultMin: 11.0,
    defaultMax: 14.6,
    severity: DriverAlertSeverity.warning,
    restValue: 12.4,
  ),
];

class AlertVariableSettings {
  bool enabled;
  double minThreshold;
  double maxThreshold;

  AlertVariableSettings({
    required this.enabled,
    required this.minThreshold,
    required this.maxThreshold,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'min': minThreshold,
        'max': maxThreshold,
      };

  static AlertVariableSettings? fromJson(Map<String, Object?> json) {
    final enabled = json['enabled'];
    final minValue = json['min'];
    final maxValue = json['max'];
    if (enabled is! bool || minValue is! num || maxValue is! num) {
      return null;
    }
    return AlertVariableSettings(
      enabled: enabled,
      minThreshold: minValue.toDouble(),
      maxThreshold: maxValue.toDouble(),
    );
  }
}
