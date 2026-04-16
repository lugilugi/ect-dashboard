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
