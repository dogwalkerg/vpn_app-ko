import 'package:vpn_app/core/api/coco_api.dart';

class TrafficAccountingState {
  final bool connected;
  final bool syncing;
  final int uploadBytesPerSecond;
  final int downloadBytesPerSecond;
  final int sessionUploadBytes;
  final int sessionDownloadBytes;
  final int pendingBytes;
  final DateTime? lastSyncedAt;
  final CocoTrafficRestriction? restriction;
  final String? notice;

  const TrafficAccountingState({
    this.connected = false,
    this.syncing = false,
    this.uploadBytesPerSecond = 0,
    this.downloadBytesPerSecond = 0,
    this.sessionUploadBytes = 0,
    this.sessionDownloadBytes = 0,
    this.pendingBytes = 0,
    this.lastSyncedAt,
    this.restriction,
    this.notice,
  });

  int get sessionBytes => sessionUploadBytes + sessionDownloadBytes;

  TrafficAccountingState copyWith({
    bool? connected,
    bool? syncing,
    int? uploadBytesPerSecond,
    int? downloadBytesPerSecond,
    int? sessionUploadBytes,
    int? sessionDownloadBytes,
    int? pendingBytes,
    DateTime? lastSyncedAt,
    CocoTrafficRestriction? restriction,
    String? notice,
    bool clearRestriction = false,
    bool clearNotice = false,
  }) {
    return TrafficAccountingState(
      connected: connected ?? this.connected,
      syncing: syncing ?? this.syncing,
      uploadBytesPerSecond: uploadBytesPerSecond ?? this.uploadBytesPerSecond,
      downloadBytesPerSecond:
          downloadBytesPerSecond ?? this.downloadBytesPerSecond,
      sessionUploadBytes: sessionUploadBytes ?? this.sessionUploadBytes,
      sessionDownloadBytes: sessionDownloadBytes ?? this.sessionDownloadBytes,
      pendingBytes: pendingBytes ?? this.pendingBytes,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      restriction: clearRestriction ? null : (restriction ?? this.restriction),
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}
