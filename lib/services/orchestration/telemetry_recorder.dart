import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

class _Observation {
  final double value;
  final DateTime time;
  final String source;
  final String? unit;
  final int? canId;
  final String quality;
  final int freshnessMs;
  final String? sampleId;
  const _Observation(
    this.value,
    this.time,
    this.source,
    this.unit,
    this.canId,
    this.quality,
    this.freshnessMs,
    this.sampleId,
  );
}

/// Capture/sampling owns domain context; transport receives complete events.
class TelemetryRecorder {
  final DashboardState state;
  final DateTime Function() nowUtc;
  final Map<String, _Observation> _latest = {};
  String _sessionId = '';
  int _sequence = 0;

  TelemetryRecorder(this.state, {DateTime Function()? nowUtc})
    : nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  int get sequence => _sequence;

  void restoreSequence(String sessionId, int sequence) {
    _sessionId = sessionId;
    _sequence = sequence;
    _latest.clear();
  }

  void _syncSession() {
    if (_sessionId == state.sessionId) return;
    _sessionId = state.sessionId;
    _sequence = 0;
    _latest.clear();
  }

  DecodedMetricEvent? record(
    String metric,
    double value, {
    DateTime? observedAtUtc,
    String source = 'can',
    String? unit,
    int? canId,
    String quality = 'ok',
    int freshnessMs = 5000,
    String? sourceSampleId,
    bool diagnostic = false,
    int? lapNumber,
  }) {
    _syncSession();
    if (_sessionId.isEmpty || (!state.isLogging && !diagnostic)) return null;
    if (!value.isFinite || metric.isEmpty || freshnessMs <= 0) return null;
    final observed = (observedAtUtc ?? nowUtc()).toUtc();
    final previous = _latest[metric];
    final observation = _Observation(
      value,
      observed,
      source,
      unit,
      canId,
      quality,
      freshnessMs,
      sourceSampleId,
    );
    if (!diagnostic) {
      // Suppressed unchanged observations still refresh source age.
      _latest[metric] = observation;
      if (previous != null &&
          previous.value == value &&
          previous.source == source &&
          previous.quality == quality &&
          sourceSampleId == null) {
        return null;
      }
    }
    return _event(
      metric,
      observation,
      observed,
      diagnostic ? 'diagnostic' : 'observation',
      lapNumber,
    );
  }

  List<DecodedMetricEvent> sampleFreshValues() {
    _syncSession();
    if (!state.isLogging) return const [];
    final now = nowUtc().toUtc();
    return [
      for (final entry in _latest.entries)
        if (entry.value.quality == 'ok' &&
            now.difference(entry.value.time).inMilliseconds >= 0 &&
            now.difference(entry.value.time).inMilliseconds <=
                entry.value.freshnessMs)
          _event(entry.key, entry.value, now, 'snapshot', null),
    ];
  }

  DecodedMetricEvent _event(
    String metric,
    _Observation observation,
    DateTime time,
    String kind,
    int? lapNumber,
  ) {
    return DecodedMetricEvent(
      metricKey: metric,
      value: observation.value,
      unit: observation.unit,
      sessionId: _sessionId,
      lapNumber: lapNumber ?? state.lapNumber,
      sessionState: state.sessionState,
      lapPhase: state.lapPhase,
      tsWallUtc: time,
      observedAtUtc: observation.time,
      tsSessionMs: state.sessionElapsedMs,
      source: observation.source,
      canId: observation.canId,
      seqInSession: ++_sequence,
      qualityFlag: observation.quality,
      sampleKind: kind,
      sourceSampleId: observation.sampleId,
      freshnessMs: observation.freshnessMs,
    );
  }
}
