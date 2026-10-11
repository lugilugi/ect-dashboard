import 'dart:async';
import 'package:flutter/foundation.dart';

class SpoolHealthStore extends ChangeNotifier {
  String? storageError;
  String? exportError;
  int rejectedRecordCount = 0;
  void updateRecordingErrors({
    String? storage,
    String? export,
    int rejected = 0,
  }) {
    storageError = storage;
    exportError = export;
    rejectedRecordCount += rejected;
    notifyListeners();
  }

  /// Clears a previous storage error without notifying when nothing changed,
  /// so the hot commit path does not rebuild listeners on every save.
  void clearStorageError() {
    if (storageError == null) return;
    storageError = null;
    notifyListeners();
  }

  /// Records rejected because the pending byte budget was exhausted. Each
  /// rejected record is counted once; it is also part of
  /// [rejectedRecordCount].
  int quotaRejectedRecordCount = 0;
  void recordQuotaRejection(int count, {required String message}) {
    if (count <= 0) return;
    quotaRejectedRecordCount += count;
    rejectedRecordCount += count;
    storageError = message;
    notifyListeners();
  }

  /// Rows in the journal_failed table: records whose identity already existed
  /// with different content. They are retained for diagnosis, never sent.
  int _failedRecordCount = 0;
  int get failedRecordCount => _failedRecordCount;
  void updateFailedRecordCount(int count) {
    final next = count < 0 ? 0 : count;
    if (next == _failedRecordCount) return;
    _failedRecordCount = next;
    notifyListeners();
  }

  /// Last delivery-path failure (connect, publish bookkeeping); null when the
  /// sender is healthy. Independent of storage/export errors.
  String? _deliveryError;
  String? get deliveryError => _deliveryError;
  void updateDeliveryError(String? error) {
    if (error == _deliveryError) return;
    _deliveryError = error;
    notifyListeners();
  }

  int _pendingPublishCount = 0;
  DateTime? _oldestEnqueuedAtUtc;
  int _oldestAgeMs = 0;
  int _pendingBytes = 0;
  int _byteCapacity = 0;
  bool _capacityWarning = false;
  int _recoveryResumeCount = 0;
  DateTime? _lastRecoveryAtUtc;
  Timer? _ageTicker;

  int get pendingPublishCount => _pendingPublishCount;
  DateTime? get oldestEnqueuedAtUtc => _oldestEnqueuedAtUtc;
  int get oldestAgeMs => _oldestAgeMs;
  int get pendingBytes => _pendingBytes;
  int get byteCapacity => _byteCapacity;
  bool get capacityWarning => _capacityWarning;
  int get recoveryResumeCount => _recoveryResumeCount;
  DateTime? get lastRecoveryAtUtc => _lastRecoveryAtUtc;

  void updateBacklog({
    required int count,
    required DateTime? oldestEnqueuedAtUtc,
  }) {
    final sanitizedCount = count < 0 ? 0 : count;
    final nextOldest = sanitizedCount > 0 ? oldestEnqueuedAtUtc : null;
    final nextAgeMs = nextOldest == null
        ? 0
        : DateTime.now().toUtc().difference(nextOldest).inMilliseconds;

    var changed =
        _pendingPublishCount != sanitizedCount ||
        _oldestEnqueuedAtUtc != nextOldest ||
        _oldestAgeMs != nextAgeMs;

    _pendingPublishCount = sanitizedCount;
    _oldestEnqueuedAtUtc = nextOldest;
    _oldestAgeMs = nextAgeMs;

    _syncTicker();

    if (changed) {
      notifyListeners();
    }
  }

  void updatePendingCapacity({
    required int pendingBytes,
    required int byteCapacity,
  }) {
    final sanitizedPending = pendingBytes < 0 ? 0 : pendingBytes;
    final sanitizedCapacity = byteCapacity < 0 ? 0 : byteCapacity;
    final warningThreshold = sanitizedCapacity <= 0
        ? 0
        : ((sanitizedCapacity * 0.8).ceil());
    final warning =
        sanitizedCapacity > 0 && sanitizedPending >= warningThreshold;

    final changed =
        _pendingBytes != sanitizedPending ||
        _byteCapacity != sanitizedCapacity ||
        _capacityWarning != warning;

    _pendingBytes = sanitizedPending;
    _byteCapacity = sanitizedCapacity;
    _capacityWarning = warning;

    if (changed) {
      notifyListeners();
    }
  }

  void recordRecoveryResume({DateTime? atUtc}) {
    _recoveryResumeCount += 1;
    _lastRecoveryAtUtc = (atUtc ?? DateTime.now().toUtc()).toUtc();
    notifyListeners();
  }

  void _syncTicker() {
    if (_pendingPublishCount > 0 && _oldestEnqueuedAtUtc != null) {
      _startTicker();
    } else {
      _stopTicker();
      if (_oldestAgeMs != 0) {
        _oldestAgeMs = 0;
      }
    }
  }

  void _startTicker() {
    if (_ageTicker != null) {
      return;
    }
    _ageTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final oldest = _oldestEnqueuedAtUtc;
      if (oldest == null || _pendingPublishCount <= 0) {
        _stopTicker();
        return;
      }

      final nextAge = DateTime.now().toUtc().difference(oldest).inMilliseconds;
      if (nextAge != _oldestAgeMs) {
        _oldestAgeMs = nextAge;
        notifyListeners();
      }
    });
  }

  void _stopTicker() {
    _ageTicker?.cancel();
    _ageTicker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}
