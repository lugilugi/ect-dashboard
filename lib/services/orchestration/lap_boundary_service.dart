import 'dart:math';

import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';

class GeoPoint {
  final double lat;
  final double lon;

  const GeoPoint({required this.lat, required this.lon});
}

class GpsSample {
  final GeoPoint point;
  final double headingDeg;
  final double speedKmh;
  final DateTime tsUtc;
  final String source;

  const GpsSample({
    required this.point,
    required this.headingDeg,
    required this.speedKmh,
    required this.tsUtc,
    required this.source,
  });
}

class LapBoundaryConfig {
  final GeoPoint finishLineStart;
  final GeoPoint finishLineEnd;
  final double expectedHeadingDeg;
  final double headingToleranceDeg;
  final double minCrossingSpeedKmh;
  final Duration minLapTime;
  final Duration deadzone;

  const LapBoundaryConfig({
    required this.finishLineStart,
    required this.finishLineEnd,
    required this.expectedHeadingDeg,
    required this.headingToleranceDeg,
    required this.minCrossingSpeedKmh,
    required this.minLapTime,
    required this.deadzone,
  });

  LapBoundaryConfig copyWith({
    GeoPoint? finishLineStart,
    GeoPoint? finishLineEnd,
    double? expectedHeadingDeg,
    double? headingToleranceDeg,
    double? minCrossingSpeedKmh,
    Duration? minLapTime,
    Duration? deadzone,
  }) {
    return LapBoundaryConfig(
      finishLineStart: finishLineStart ?? this.finishLineStart,
      finishLineEnd: finishLineEnd ?? this.finishLineEnd,
      expectedHeadingDeg: expectedHeadingDeg ?? this.expectedHeadingDeg,
      headingToleranceDeg: headingToleranceDeg ?? this.headingToleranceDeg,
      minCrossingSpeedKmh: minCrossingSpeedKmh ?? this.minCrossingSpeedKmh,
      minLapTime: minLapTime ?? this.minLapTime,
      deadzone: deadzone ?? this.deadzone,
    );
  }
}

enum LapCrossingDecision {
  none,
  deadzone,
  rejected,
  accepted,
}

class LapBoundaryResult {
  final LapCrossingDecision decision;
  final LapCrossingEvent? crossingEvent;
  final int deadzoneRemainingMs;

  const LapBoundaryResult({
    required this.decision,
    required this.crossingEvent,
    required this.deadzoneRemainingMs,
  });

  static const none = LapBoundaryResult(
    decision: LapCrossingDecision.none,
    crossingEvent: null,
    deadzoneRemainingMs: 0,
  );
}

class LapBoundaryService {
  LapBoundaryConfig _config;
  GpsSample? _previousSample;
  DateTime? _lastAcceptedCrossingAtUtc;

  LapBoundaryService({required LapBoundaryConfig config}) : _config = config;

  factory LapBoundaryService.defaultConfig() {
    return LapBoundaryService(
      config: const LapBoundaryConfig(
        finishLineStart: GeoPoint(lat: 0, lon: 0),
        finishLineEnd: GeoPoint(lat: 0, lon: 0.0001),
        expectedHeadingDeg: 0,
        headingToleranceDeg: 45,
        minCrossingSpeedKmh: 0.5,
        minLapTime: Duration(seconds: 45),
        deadzone: Duration(seconds: 3),
      ),
    );
  }

  LapBoundaryConfig get config => _config;

  void setFinishLine({required GeoPoint start, required GeoPoint end}) {
    _config = _config.copyWith(finishLineStart: start, finishLineEnd: end);
    resetTracking();
  }

  void setDeadzone(Duration deadzone) {
    if (deadzone.inMilliseconds == _config.deadzone.inMilliseconds) {
      return;
    }
    _config = _config.copyWith(deadzone: deadzone);
  }

  void resetTracking() {
    _previousSample = null;
    _lastAcceptedCrossingAtUtc = null;
  }

  LapBoundaryResult processSample({
    required GpsSample sample,
    required SessionControlState control,
    required String sessionId,
    required int lapNumber,
  }) {
    final previous = _previousSample;
    _previousSample = sample;

    if (previous == null) {
      return LapBoundaryResult.none;
    }

    final deadzoneRemaining = _deadzoneRemainingMs(sample.tsUtc);
    if (deadzoneRemaining > 0) {
      return LapBoundaryResult(
        decision: LapCrossingDecision.deadzone,
        crossingEvent: null,
        deadzoneRemainingMs: deadzoneRemaining,
      );
    }

    if (!_segmentsIntersect(
      previous.point,
      sample.point,
      _config.finishLineStart,
      _config.finishLineEnd,
    )) {
      return LapBoundaryResult.none;
    }

    final headingOk = _headingWithinTolerance(
      sample.headingDeg,
      _config.expectedHeadingDeg,
      _config.headingToleranceDeg,
    );
    final speedOk = sample.speedKmh >= _config.minCrossingSpeedKmh;
    final lapTimeOk = _lastAcceptedCrossingAtUtc == null ||
        sample.tsUtc.difference(_lastAcceptedCrossingAtUtc!) >=
            _config.minLapTime;

    final accepted = headingOk && speedOk && lapTimeOk;
    final reason = accepted
        ? null
        : !speedOk
            ? 'speed_below_threshold'
            : !headingOk
                ? 'heading_out_of_tolerance'
                : 'min_lap_time_not_met';

    final confidence = _crossingConfidence(
      headingDeg: sample.headingDeg,
      speedKmh: sample.speedKmh,
      headingOk: headingOk,
      speedOk: speedOk,
      lapTimeOk: lapTimeOk,
    );

    if (accepted) {
      _lastAcceptedCrossingAtUtc = sample.tsUtc;
    }

    final crossingEvent = LapCrossingEvent(
      sessionId: sessionId,
      lapNumber: lapNumber,
      tsWallUtc: sample.tsUtc,
      tsSessionMs: 0,
      lapPhase: accepted ? LapPhase.lapComplete : LapPhase.crossingCandidate,
      crossingValid: accepted,
      reason: reason,
      confidence: confidence,
      lat: sample.point.lat,
      lon: sample.point.lon,
      headingDeg: sample.headingDeg,
      speedKmh: sample.speedKmh,
    );

    return LapBoundaryResult(
      decision:
          accepted ? LapCrossingDecision.accepted : LapCrossingDecision.rejected,
      crossingEvent: crossingEvent,
      deadzoneRemainingMs: accepted ? _config.deadzone.inMilliseconds : 0,
    );
  }

  int _deadzoneRemainingMs(DateTime nowUtc) {
    if (_lastAcceptedCrossingAtUtc == null) {
      return 0;
    }

    final elapsed = nowUtc.difference(_lastAcceptedCrossingAtUtc!);
    final remaining = _config.deadzone - elapsed;
    if (remaining <= Duration.zero) {
      return 0;
    }
    return remaining.inMilliseconds;
  }

  bool _headingWithinTolerance(
    double currentHeading,
    double expectedHeading,
    double tolerance,
  ) {
    final delta = ((currentHeading - expectedHeading + 540) % 360) - 180;
    return delta.abs() <= tolerance;
  }

  double _crossingConfidence({
    required double headingDeg,
    required double speedKmh,
    required bool headingOk,
    required bool speedOk,
    required bool lapTimeOk,
  }) {
    final headingDelta =
        (((headingDeg - _config.expectedHeadingDeg + 540) % 360) - 180).abs();
    final headingScore =
        max(0.0, 1.0 - (headingDelta / max(_config.headingToleranceDeg, 1.0)));
    final speedScore = max(0.0, min(1.0, speedKmh / max(_config.minCrossingSpeedKmh, 0.1)));

    var score = 0.5 * headingScore + 0.5 * speedScore;
    if (!headingOk || !speedOk || !lapTimeOk) {
      score *= 0.5;
    }
    return score.clamp(0.0, 1.0);
  }

  bool _segmentsIntersect(
    GeoPoint p1,
    GeoPoint q1,
    GeoPoint p2,
    GeoPoint q2,
  ) {
    final o1 = _orientation(p1, q1, p2);
    final o2 = _orientation(p1, q1, q2);
    final o3 = _orientation(p2, q2, p1);
    final o4 = _orientation(p2, q2, q1);

    if (o1 != o2 && o3 != o4) {
      return true;
    }

    if (o1 == 0 && _onSegment(p1, p2, q1)) {
      return true;
    }
    if (o2 == 0 && _onSegment(p1, q2, q1)) {
      return true;
    }
    if (o3 == 0 && _onSegment(p2, p1, q2)) {
      return true;
    }
    if (o4 == 0 && _onSegment(p2, q1, q2)) {
      return true;
    }

    return false;
  }

  int _orientation(GeoPoint p, GeoPoint q, GeoPoint r) {
    final val =
        (q.lon - p.lon) * (r.lat - q.lat) - (q.lat - p.lat) * (r.lon - q.lon);

    if (val.abs() < 1e-12) {
      return 0;
    }
    return val > 0 ? 1 : 2;
  }

  bool _onSegment(GeoPoint p, GeoPoint q, GeoPoint r) {
    return q.lon <= max(p.lon, r.lon) &&
        q.lon >= min(p.lon, r.lon) &&
        q.lat <= max(p.lat, r.lat) &&
        q.lat >= min(p.lat, r.lat);
  }
}