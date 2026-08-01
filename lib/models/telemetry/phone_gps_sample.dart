class PhoneGpsSample {
  final double latitude;
  final double longitude;
  final double headingDeg;
  final double speedMps;
  final double accuracyM;
  final DateTime timestampUtc;
  final int satelliteCount;

  const PhoneGpsSample({
    required this.latitude,
    required this.longitude,
    required this.headingDeg,
    required this.speedMps,
    required this.accuracyM,
    required this.timestampUtc,
    this.satelliteCount = -1,
  });

  double get speedKmh => speedMps * 3.6;

  bool get locked => accuracyM <= 50.0;
}
