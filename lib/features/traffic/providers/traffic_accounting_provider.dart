import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/features/auth/providers/auth_providers.dart';
import 'package:vpn_app/features/subscription/models/subscription_state.dart';
import 'package:vpn_app/features/subscription/providers/subscription_providers.dart';
import 'package:vpn_app/features/traffic/models/traffic_accounting_state.dart';
import 'package:vpn_app/features/vpn/platform/vpn_channel.dart';
import 'package:vpn_app/features/vpn/providers/subscription_nodes_provider.dart';
import 'package:vpn_app/features/vpn/providers/vpn_controller.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';

final trafficAccountingProvider =
    StateNotifierProvider<TrafficAccountingController, TrafficAccountingState>((
      ref,
    ) {
      return TrafficAccountingController(ref, ref.read(cocoApiProvider));
    }, name: 'trafficAccounting');

final trafficFlushProvider = Provider<Future<bool> Function()>((ref) {
  return ref.read(trafficAccountingProvider.notifier).flush;
}, name: 'trafficFlush');

final trafficBatchCheckIntervalProvider = Provider<Duration>(
  (_) => const Duration(seconds: 5),
  name: 'trafficBatchCheckInterval',
);
final trafficRetryBackoffProvider = Provider<Duration>(
  (_) => TrafficAccountingController.heartbeatInterval,
  name: 'trafficRetryBackoff',
);

typedef _AccountMetadataBasis = ({
  bool canUse,
  String subUrl,
  String? paidUntil,
  int trafficTotal,
  int trafficUsed,
  int level,
  String? updatedAt,
});

class TrafficAccountingController extends StateNotifier<TrafficAccountingState>
    with WidgetsBindingObserver {
  TrafficAccountingController(this._ref, this._api)
    : super(const TrafficAccountingState()) {
    WidgetsBinding.instance.addObserver(this);
    _vpnEvents = VpnChannel().onStatus.listen(_onVpnEvent);
    _ref.listen<String?>(tokenProvider, _onTokenChanged, fireImmediately: true);
    _ref.listen<VpnState>(
      vpnControllerProvider,
      _onVpnStateChanged,
      fireImmediately: true,
    );
    _ref.listen<bool>(vpnAccessProvider, (previous, allowed) {
      if (allowed &&
          state.restriction == CocoTrafficRestriction.quotaOrExpired) {
        state = state.copyWith(clearRestriction: true, clearNotice: true);
      }
    });
  }

  static const reportThresholdBytes = 100 * 1024 * 1024;
  static const reportInterval = Duration(minutes: 15);
  static const heartbeatInterval = Duration(minutes: 5);

  final Ref _ref;
  final CocoApi _api;
  StreamSubscription<VpnStatusEvent>? _vpnEvents;
  Timer? _heartbeatTimer;
  Timer? _batchTimer;
  Timer? _desktopPollTimer;
  Future<void> _operationTail = Future<void>.value();
  Future<bool>? _batchFlushFuture;
  bool _disposed = false;
  bool _desktopPollBusy = false;
  bool _enforcingRestriction = false;
  bool _automaticFlushScheduled = false;
  int _pendingBytes = 0;
  _PendingTrafficBatch? _retryBatch;
  _PendingTrafficBatch? _queuedBatch;
  bool _retryBatchNeedsRetry = false;
  DateTime? _nextRetryAt;
  String? _accountKey;
  Future<void> _restoreFuture = Future<void>.value();
  DateTime _lastBatchReportAt = DateTime.now();
  DateTime? _lastAccountSyncAt;
  DateTime? _lastAccountSyncAttemptAt;
  String? _nativeSessionId;
  int _lastNativeUpload = 0;
  int _lastNativeDownload = 0;
  bool _nativeCursorRestored = true;
  VpnStatusEvent? _deferredNativeEvent;
  int? _lastDesktopUpload;
  int? _lastDesktopDownload;
  DateTime? _lastDesktopSampleAt;

  void _onTokenChanged(String? previous, String? token) {
    if (token == null || token.isEmpty) {
      _stopAccountChecks();
      _accountKey = null;
      _restoreFuture = Future<void>.value();
      _nativeCursorRestored = true;
      _deferredNativeEvent = null;
      _resetCounters(clearRestriction: true);
      return;
    }
    final accountKey = sha256.convert(utf8.encode(token)).toString();
    if (previous != token) {
      _pendingBytes = 0;
      _retryBatch = null;
      _queuedBatch = null;
      _retryBatchNeedsRetry = false;
      _nextRetryAt = null;
      _lastAccountSyncAt = null;
      _lastAccountSyncAttemptAt = null;
      _nativeSessionId = null;
      _lastNativeUpload = 0;
      _lastNativeDownload = 0;
      _deferredNativeEvent = null;
      _publishPending(syncing: false);
    }
    _accountKey = accountKey;
    _nativeCursorRestored = false;
    _restoreFuture = _restorePendingBatch(accountKey);
    _startAccountChecks();
    _updateHeartbeatTimer();
    if (previous != token) {
      _lastBatchReportAt = DateTime.now();
      unawaited(
        _restoreFuture.then((_) async {
          if (_retryBatch != null) await flush();
        }),
      );
    }
  }

  void _startAccountChecks() {
    _batchTimer ??= Timer.periodic(
      _ref.read(trafficBatchCheckIntervalProvider),
      (_) => unawaited(_onBatchTick()),
    );
  }

  void _updateHeartbeatTimer() {
    final shouldRun = _hasToken && state.connected;
    if (!shouldRun) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      return;
    }
    _heartbeatTimer ??= Timer.periodic(
      heartbeatInterval,
      (_) => unawaited(heartbeat()),
    );
  }

  Future<void> _onBatchTick() async {
    if (_disposed) return;
    await _checkpointPending();
    if (_disposed) return;
    if (!state.connected || _displayPendingBytes <= 0) return;
    if (_retryBatchNeedsRetry ||
        DateTime.now().difference(_lastBatchReportAt) >= reportInterval) {
      await _flushAutomaticallyIfDue();
    }
  }

  void _stopAccountChecks() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _batchTimer?.cancel();
    _batchTimer = null;
  }

  void _onVpnStateChanged(VpnState? previous, VpnState next) {
    final wasActive = previous is VpnConnected || previous is VpnDisconnecting;
    final active = next is VpnConnected || next is VpnDisconnecting;
    if (!wasActive && next is VpnConnected) {
      _beginConnection();
    } else if (wasActive && !active) {
      _finishConnection();
    }
  }

  void _beginConnection() {
    _lastBatchReportAt = DateTime.now();
    _lastDesktopUpload = null;
    _lastDesktopDownload = null;
    _lastDesktopSampleAt = null;
    state = state.copyWith(
      connected: true,
      uploadBytesPerSecond: 0,
      downloadBytesPerSecond: 0,
      sessionUploadBytes: 0,
      sessionDownloadBytes: 0,
      clearNotice: true,
    );
    _updateHeartbeatTimer();
    unawaited(
      _restoreFuture.then((_) async {
        if (_retryBatchNeedsRetry && state.connected) await _flushOneBatch();
      }),
    );
    if (Platform.isWindows || Platform.isMacOS) {
      _desktopPollTimer?.cancel();
      _desktopPollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_pollDesktopTraffic()),
      );
      unawaited(_pollDesktopTraffic());
    }
  }

  void _finishConnection() {
    _desktopPollTimer?.cancel();
    _desktopPollTimer = null;
    state = state.copyWith(
      connected: false,
      uploadBytesPerSecond: 0,
      downloadBytesPerSecond: 0,
    );
    _updateHeartbeatTimer();
    unawaited(flush());
  }

  void _onVpnEvent(VpnStatusEvent event) {
    if ((event.stage != VpnStage.connected &&
            event.stage != VpnStage.disconnecting) ||
        event.uploadBytesTotal == null ||
        event.downloadBytesTotal == null) {
      return;
    }

    if (!_nativeCursorRestored) {
      _deferredNativeEvent = event;
      return;
    }
    unawaited(_enqueue(() => _processNativeEvent(event)));
  }

  Future<void> _processNativeEvent(VpnStatusEvent event) async {
    if (_disposed ||
        _enforcingRestriction ||
        event.uploadBytesTotal == null ||
        event.downloadBytesTotal == null) {
      return;
    }

    final sessionId = event.sessionId ?? 'native';
    if (_nativeSessionId != sessionId) {
      _nativeSessionId = sessionId;
      _lastNativeUpload = 0;
      _lastNativeDownload = 0;
    }

    final uploadTotal = event.uploadBytesTotal! < 0
        ? 0
        : event.uploadBytesTotal!;
    final downloadTotal = event.downloadBytesTotal! < 0
        ? 0
        : event.downloadBytesTotal!;
    final uploadDelta = uploadTotal >= _lastNativeUpload
        ? uploadTotal - _lastNativeUpload
        : 0;
    final downloadDelta = downloadTotal >= _lastNativeDownload
        ? downloadTotal - _lastNativeDownload
        : 0;

    // Persist the new cursor and its unreported delta in one JSON value before
    // publishing it in memory. If Flutter is killed after this write, restore
    // resumes from the same cursor and pending byte count. If the write fails,
    // the old cursor is retained on disk so a restart may replay, but never
    // silently lose, those bytes.
    final prospectivePending = _pendingBytes + uploadDelta + downloadDelta;
    await _persistLedger(
      pendingBytes: prospectivePending,
      nativeSessionId: sessionId,
      nativeUpload: uploadTotal,
      nativeDownload: downloadTotal,
    );
    _lastNativeUpload = uploadTotal;
    _lastNativeDownload = downloadTotal;

    _recordTraffic(
      uploadDelta: uploadDelta,
      downloadDelta: downloadDelta,
      uploadSpeed: event.uploadBytesPerSecond ?? 0,
      downloadSpeed: event.downloadBytesPerSecond ?? 0,
      allowDisconnected: event.stage == VpnStage.disconnecting,
    );
  }

  Future<void> _pollDesktopTraffic() async {
    if (_desktopPollBusy || !state.connected || _disposed) return;
    _desktopPollBusy = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:9090/connections'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      final body = await utf8.decoder.bind(response).join();
      final data = jsonDecode(body);
      if (data is! Map) return;
      final upload = _asInt(data['uploadTotal']);
      final download = _asInt(data['downloadTotal']);
      final now = DateTime.now();
      final previousUpload = _lastDesktopUpload;
      final previousDownload = _lastDesktopDownload;
      final previousAt = _lastDesktopSampleAt;
      _lastDesktopUpload = upload;
      _lastDesktopDownload = download;
      _lastDesktopSampleAt = now;
      if (previousUpload == null ||
          previousDownload == null ||
          previousAt == null) {
        return;
      }
      final uploadDelta = upload >= previousUpload
          ? upload - previousUpload
          : 0;
      final downloadDelta = download >= previousDownload
          ? download - previousDownload
          : 0;
      final elapsedMs = now
          .difference(previousAt)
          .inMilliseconds
          .clamp(1, 60000);
      _recordTraffic(
        uploadDelta: uploadDelta,
        downloadDelta: downloadDelta,
        uploadSpeed: (uploadDelta * 1000 / elapsedMs).round(),
        downloadSpeed: (downloadDelta * 1000 / elapsedMs).round(),
      );
    } catch (_) {
      // The core can be starting or stopping between polls.
    } finally {
      client.close(force: true);
      _desktopPollBusy = false;
    }
  }

  void _recordTraffic({
    required int uploadDelta,
    required int downloadDelta,
    required int uploadSpeed,
    required int downloadSpeed,
    bool allowDisconnected = false,
  }) {
    if ((!state.connected && !allowDisconnected) || _enforcingRestriction) {
      return;
    }
    final delta = uploadDelta + downloadDelta;
    if (delta > 0) _pendingBytes += delta;
    state = state.copyWith(
      uploadBytesPerSecond: uploadSpeed,
      downloadBytesPerSecond: downloadSpeed,
      sessionUploadBytes: state.sessionUploadBytes + uploadDelta,
      sessionDownloadBytes: state.sessionDownloadBytes + downloadDelta,
      pendingBytes: _displayPendingBytes,
    );
    if (!_retryBatchNeedsRetry &&
        _displayPendingBytes >= reportThresholdBytes) {
      _scheduleAutomaticFlush();
    }
  }

  void _scheduleAutomaticFlush() {
    unawaited(_flushAutomaticallyIfDue());
  }

  Future<bool> _flushAutomaticallyIfDue() async {
    if (_automaticFlushScheduled) return false;
    final now = DateTime.now();
    final pendingBytes = _displayPendingBytes;
    if (!_retryBatchNeedsRetry &&
        (pendingBytes <= 0 ||
            (pendingBytes < reportThresholdBytes &&
                now.difference(_lastBatchReportAt) < reportInterval))) {
      return false;
    }
    final nextRetryAt = _nextRetryAt;
    if (_retryBatchNeedsRetry &&
        nextRetryAt != null &&
        now.isBefore(nextRetryAt)) {
      return false;
    }
    _automaticFlushScheduled = true;
    if (_retryBatchNeedsRetry) {
      _nextRetryAt = now.add(_ref.read(trafficRetryBackoffProvider));
    }
    try {
      return await _flushOneBatch();
    } finally {
      _automaticFlushScheduled = false;
    }
  }

  Future<void> _checkpointPending() {
    return _enqueue(() async {
      await _restoreFuture;
      if (_disposed) return;
      if (!_hasToken || _pendingBytes <= 0) return;
      final existing = _retryBatch;
      if (existing != null) {
        if (_retryBatchNeedsRetry) {
          final queued = _queuedBatch;
          final combined = _PendingTrafficBatch(
            id: queued?.id ?? const Uuid().v4(),
            bytes: (queued?.bytes ?? 0) + _pendingBytes,
          );
          if (await _persistPendingBatches(
            existing,
            combined,
            pendingBytes: 0,
          )) {
            _pendingBytes = 0;
            _queuedBatch = combined;
            _publishPending(syncing: false);
          }
          return;
        }
        final combined = _PendingTrafficBatch(
          id: existing.id,
          bytes: existing.bytes + _pendingBytes,
        );
        if (await _persistPendingBatch(combined, pendingBytes: 0)) {
          _pendingBytes = 0;
          _retryBatch = combined;
          _publishPending(syncing: false);
        }
        return;
      }
      final batch = _PendingTrafficBatch(
        id: const Uuid().v4(),
        bytes: _pendingBytes,
      );
      if (await _persistPendingBatch(batch, pendingBytes: 0)) {
        _pendingBytes = 0;
        _retryBatch = batch;
        _retryBatchNeedsRetry = false;
        _publishPending(syncing: false);
      }
    });
  }

  Future<void> heartbeat({bool allowDisconnected = false}) async {
    await _restoreFuture;
    final now = DateTime.now();
    final pendingBytes = _displayPendingBytes;
    final pendingIsDue =
        _retryBatchNeedsRetry ||
        (pendingBytes > 0 &&
            (pendingBytes >= reportThresholdBytes ||
                now.difference(_lastBatchReportAt) >= reportInterval));
    if (pendingIsDue) {
      await _flushAutomaticallyIfDue();
      return;
    }
    if (state.restriction != null) return;
    await _enqueue(() async {
      if (!_hasToken ||
          (!state.connected && !allowDisconnected) ||
          _enforcingRestriction) {
        return;
      }
      final lastSync = _lastAccountSyncAt;
      if (lastSync != null &&
          DateTime.now().difference(lastSync) < heartbeatInterval) {
        return;
      }
      final lastAttempt = _lastAccountSyncAttemptAt;
      if (lastAttempt != null &&
          DateTime.now().difference(lastAttempt) < heartbeatInterval) {
        return;
      }
      try {
        final metadataBasis = _accountMetadataBasis;
        final requestToken = _ref.read(tokenProvider);
        _lastAccountSyncAttemptAt = DateTime.now();
        final report = await _api.reportTraffic(0);
        await _applyReport(
          report,
          metadataBasis: metadataBasis,
          requestToken: requestToken,
        );
      } catch (_) {
        // Heartbeats are retried on the next interval.
      }
    });
  }

  Future<void> resumeFromBackground() async {
    if (!_hasToken) return;
    await _restoreFuture;
    if (_retryBatchNeedsRetry) await _flushAutomaticallyIfDue();
    await heartbeat(allowDisconnected: true);
    try {
      await _ref
          .read(subscriptionNodesRefreshControllerProvider.notifier)
          .refreshNodesIfDue();
    } catch (_) {}
  }

  Future<bool> flush() {
    return _drainPendingTraffic();
  }

  Future<bool> _drainPendingTraffic() async {
    if ((Platform.isWindows || Platform.isMacOS) && state.connected) {
      await _captureDesktopTrafficBeforeFlush();
    }
    while (_displayPendingBytes > 0) {
      if (!await _flushOneBatch(captureDesktop: false)) return false;
    }
    return true;
  }

  Future<bool> _flushOneBatch({bool captureDesktop = true}) {
    final active = _batchFlushFuture;
    if (active != null) return active;
    late final Future<bool> future;
    future = _performFlush(captureDesktop: captureDesktop).whenComplete(() {
      if (identical(_batchFlushFuture, future)) _batchFlushFuture = null;
    });
    _batchFlushFuture = future;
    return future;
  }

  Future<bool> _performFlush({required bool captureDesktop}) async {
    if (captureDesktop &&
        (Platform.isWindows || Platform.isMacOS) &&
        state.connected) {
      await _captureDesktopTrafficBeforeFlush();
    }
    var allReported = true;
    await _enqueue(() async {
      await _restoreFuture;
      if (!_hasToken || _enforcingRestriction) {
        allReported = _displayPendingBytes == 0;
        return;
      }

      final existing = _retryBatch;
      if (existing != null && !_retryBatchNeedsRetry && _pendingBytes > 0) {
        final combined = _PendingTrafficBatch(
          id: existing.id,
          bytes: existing.bytes + _pendingBytes,
        );
        if (!await _persistPendingBatch(combined, pendingBytes: 0)) {
          allReported = false;
          return;
        }
        _pendingBytes = 0;
        _retryBatch = combined;
        _publishPending(syncing: false);
      }

      var batch = _retryBatch;
      if (batch == null && _pendingBytes > 0) {
        batch = _PendingTrafficBatch(
          id: const Uuid().v4(),
          bytes: _pendingBytes,
        );
        if (!await _persistPendingBatch(batch, pendingBytes: 0)) {
          allReported = false;
          return;
        }
        _pendingBytes = 0;
        _retryBatch = batch;
      }
      if (batch == null) return;

      _publishPending(syncing: true);
      late final CocoTrafficReport report;
      final metadataBasis = _accountMetadataBasis;
      final requestToken = _ref.read(tokenProvider);
      try {
        report = await _api.reportTraffic(batch.bytes, reportId: batch.id);
      } catch (_) {
        _retryBatchNeedsRetry = true;
        _nextRetryAt = DateTime.now().add(
          _ref.read(trafficRetryBackoffProvider),
        );
        allReported = false;
        _publishPending(syncing: false);
        return;
      }

      if (!await _removePendingBatch(batch)) {
        _retryBatchNeedsRetry = true;
        _nextRetryAt = DateTime.now().add(
          _ref.read(trafficRetryBackoffProvider),
        );
        allReported = false;
        _publishPending(syncing: false);
        return;
      }
      _retryBatch = _queuedBatch;
      _queuedBatch = null;
      _retryBatchNeedsRetry = false;
      _nextRetryAt = null;
      _lastBatchReportAt = DateTime.now();
      _publishPending(syncing: true);
      try {
        await _applyReport(
          report,
          metadataBasis: metadataBasis,
          requestToken: requestToken,
        );
      } finally {
        _publishPending(syncing: false);
      }
    });
    return allReported;
  }

  Future<void> _captureDesktopTrafficBeforeFlush() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_desktopPollBusy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _pollDesktopTraffic();
  }

  Future<void> _applyReport(
    CocoTrafficReport report, {
    required _AccountMetadataBasis metadataBasis,
    required String? requestToken,
  }) async {
    if (requestToken == null || requestToken != _ref.read(tokenProvider)) {
      return;
    }
    if (report.restriction == CocoTrafficRestriction.unauthorized) {
      _lastAccountSyncAt = DateTime.now();
      await _enforceRestriction(report);
      return;
    }
    final currentBasis = _accountMetadataBasis;
    final accountUpdatedAt = report.account?.updatedAt;
    final currentUpdatedAt = DateTime.tryParse(currentBasis.updatedAt ?? '');
    final accountIsStale =
        accountUpdatedAt != null &&
        currentUpdatedAt != null &&
        accountUpdatedAt.isBefore(currentUpdatedAt);
    final canApply =
        !accountIsStale &&
        (accountUpdatedAt != null || metadataBasis == currentBasis);
    if (!canApply) return;

    _lastAccountSyncAt = DateTime.now();
    if (report.hasTrafficSnapshot) {
      final account = report.account;
      await _ref
          .read(subscriptionControllerProvider.notifier)
          .applyTrafficSnapshot(
            total: report.trafficTotal,
            used: report.trafficUsed,
            canUse: report.restriction == null
                ? account?.canUse ?? report.restriction == null
                : null,
            paidUntil: account != null
                ? account.expiresAt?.toIso8601String() ?? ''
                : null,
            subUrl: account?.subscriptionUrl,
            updatedAt: account?.updatedAt?.toIso8601String(),
          );
    }
    if (report.restriction == null) {
      state = state.copyWith(
        lastSyncedAt: DateTime.now(),
        clearRestriction: true,
        clearNotice: true,
      );
      return;
    }
    await _enforceRestriction(report);
  }

  Future<void> _enforceRestriction(CocoTrafficReport report) async {
    if (_enforcingRestriction) return;
    _enforcingRestriction = true;
    _pendingBytes = 0;
    if (_retryBatch != null || _queuedBatch != null) {
      await _clearPersistedBatches();
      _retryBatch = null;
      _queuedBatch = null;
      _retryBatchNeedsRetry = false;
      _nextRetryAt = null;
    }
    _publishPending(syncing: false);
    final message = _restrictionMessage(report);
    try {
      try {
        await _ref.read(vpnControllerProvider.notifier).forceDisconnect();
      } catch (_) {}
      await _ref.read(subscriptionControllerProvider.notifier).markBlocked();
      _ref
          .read(nodeSelectionModeProvider.notifier)
          .cancelPendingSelection(clearNode: true);
      _ref.invalidate(subscriptionNodesProvider);
      state = state.copyWith(
        restriction: report.restriction,
        notice: message,
        connected: false,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      );
      if (_ref.read(vpnControllerProvider) is! VpnIdle) {
        try {
          await _ref.read(vpnControllerProvider.notifier).forceDisconnect();
        } catch (_) {
          state = state.copyWith(notice: '$message；代理停止失败，请手动关闭系统 VPN');
        }
      }
      if (report.restriction == CocoTrafficRestriction.unauthorized ||
          report.restriction == CocoTrafficRestriction.accountDisabled) {
        await _ref
            .read(authControllerProvider.notifier)
            .clearLocalSession(notice: message);
      }
    } finally {
      _enforcingRestriction = false;
    }
  }

  String _restrictionMessage(CocoTrafficReport report) {
    return switch (report.restriction) {
      CocoTrafficRestriction.quotaOrExpired => '流量已用完或会员已到期，请充值或购买套餐后继续使用',
      CocoTrafficRestriction.accountDisabled => '账号已被禁用，请联系管理员',
      CocoTrafficRestriction.unauthorized => '登录已失效，请重新登录',
      null => report.message,
    };
  }

  void _publishPending({required bool syncing}) {
    if (_disposed) return;
    state = state.copyWith(
      syncing: syncing,
      pendingBytes: _displayPendingBytes,
    );
  }

  int get _displayPendingBytes =>
      _pendingBytes + (_retryBatch?.bytes ?? 0) + (_queuedBatch?.bytes ?? 0);

  _AccountMetadataBasis get _accountMetadataBasis {
    if (!_ref.exists(subscriptionControllerProvider)) {
      return (
        canUse: false,
        subUrl: '',
        paidUntil: null,
        trafficTotal: 0,
        trafficUsed: 0,
        level: 0,
        updatedAt: null,
      );
    }
    try {
      final subscription = _ref.read(subscriptionControllerProvider);
      if (subscription is SubscriptionReady) {
        return (
          canUse: subscription.status.canUse,
          subUrl: subscription.status.subUrl.trim(),
          paidUntil: subscription.status.paidUntil,
          trafficTotal: subscription.status.trafficTotal,
          trafficUsed: subscription.status.trafficUsed,
          level: subscription.status.level,
          updatedAt: subscription.status.updatedAt,
        );
      }
    } catch (_) {}
    return (
      canUse: false,
      subUrl: '',
      paidUntil: null,
      trafficTotal: 0,
      trafficUsed: 0,
      level: 0,
      updatedAt: null,
    );
  }

  String _pendingStorageKey(String accountKey) =>
      'traffic.pending.v1.$accountKey';

  Future<void> _restorePendingBatch(String accountKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingStorageKey(accountKey));
      if (_accountKey != accountKey || raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final batches = data['batches'] is List
          ? (data['batches'] as List)
                .map(_batchFromJson)
                .whereType<_PendingTrafficBatch>()
                .take(2)
                .toList()
          : <_PendingTrafficBatch>[
              if (_batchFromJson(data) case final batch?) batch,
            ];
      _retryBatch = batches.isEmpty ? null : batches.first;
      _queuedBatch = batches.length > 1 ? batches[1] : null;
      _retryBatchNeedsRetry = _retryBatch != null;
      _pendingBytes = _asInt(data['pending_bytes']);
      final cursor = data['native_cursor'];
      if (cursor is Map) {
        final sessionId = cursor['session_id']?.toString().trim() ?? '';
        if (sessionId.isNotEmpty) {
          _nativeSessionId = sessionId;
          _lastNativeUpload = _asInt(cursor['upload']);
          _lastNativeDownload = _asInt(cursor['download']);
        }
      }
      _nextRetryAt = null;
      _publishPending(syncing: false);
    } catch (_) {
      // A later flush can still persist newly collected traffic.
    } finally {
      if (_accountKey == accountKey) {
        _nativeCursorRestored = true;
        final deferred = _deferredNativeEvent;
        _deferredNativeEvent = null;
        if (deferred != null) {
          unawaited(_enqueue(() => _processNativeEvent(deferred)));
        }
      }
    }
  }

  Future<bool> _persistPendingBatch(
    _PendingTrafficBatch batch, {
    int? pendingBytes,
  }) async {
    return _persistPendingBatches(
      batch,
      _queuedBatch,
      pendingBytes: pendingBytes,
    );
  }

  Future<bool> _persistPendingBatches(
    _PendingTrafficBatch head,
    _PendingTrafficBatch? queued, {
    int? pendingBytes,
  }) async {
    return _persistLedger(
      batches: [head, if (queued != null) queued],
      pendingBytes: pendingBytes,
    );
  }

  Future<bool> _persistLedger({
    List<_PendingTrafficBatch>? batches,
    int? pendingBytes,
    String? nativeSessionId,
    int? nativeUpload,
    int? nativeDownload,
  }) async {
    final accountKey = _accountKey;
    if (accountKey == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionId = nativeSessionId ?? _nativeSessionId;
      return prefs.setString(
        _pendingStorageKey(accountKey),
        jsonEncode({
          'version': 2,
          'batches':
              (batches ??
                      [
                        if (_retryBatch != null) _retryBatch!,
                        if (_queuedBatch != null) _queuedBatch!,
                      ])
                  .map(_batchToJson)
                  .toList(),
          'pending_bytes': pendingBytes ?? _pendingBytes,
          if (sessionId != null && sessionId.isNotEmpty)
            'native_cursor': {
              'session_id': sessionId,
              'upload': nativeUpload ?? _lastNativeUpload,
              'download': nativeDownload ?? _lastNativeDownload,
            },
        }),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _removePendingBatch(_PendingTrafficBatch batch) async {
    final accountKey = _accountKey;
    if (accountKey == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _pendingStorageKey(accountKey);
      final raw = prefs.getString(key);
      if (raw == null) return true;
      final data = jsonDecode(raw);
      if (data is! Map) return false;
      final batches = data['batches'] is List
          ? data['batches'] as List
          : <dynamic>[data];
      final persistedHead = batches.isEmpty
          ? null
          : _batchFromJson(batches.first);
      if (persistedHead?.id != batch.id) {
        return false;
      }
      final queued = _queuedBatch;
      return _persistLedger(batches: [if (queued != null) queued]);
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearPersistedBatches() async {
    final accountKey = _accountKey;
    if (accountKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingStorageKey(accountKey));
    } catch (_) {}
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final completer = Completer<void>();
    _operationTail = _operationTail
        .then((_) async {
          if (_disposed) {
            completer.complete();
            return;
          }
          try {
            await operation();
            completer.complete();
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .catchError((_) {
          if (!completer.isCompleted) completer.complete();
        });
    return completer.future;
  }

  bool get _hasToken {
    final token = _ref.read(tokenProvider);
    return token != null && token.isNotEmpty;
  }

  void _resetCounters({required bool clearRestriction}) {
    _pendingBytes = 0;
    _retryBatch = null;
    _queuedBatch = null;
    _retryBatchNeedsRetry = false;
    _nextRetryAt = null;
    _nativeSessionId = null;
    _lastNativeUpload = 0;
    _lastNativeDownload = 0;
    _nativeCursorRestored = _accountKey == null;
    _deferredNativeEvent = null;
    _lastDesktopUpload = null;
    _lastDesktopDownload = null;
    _lastDesktopSampleAt = null;
    _lastAccountSyncAt = null;
    _lastAccountSyncAttemptAt = null;
    if (!_disposed) {
      state = TrafficAccountingState(
        restriction: clearRestriction ? null : state.restriction,
        notice: clearRestriction ? null : state.notice,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_checkpointPending());
    } else if (state == AppLifecycleState.resumed && _hasToken) {
      unawaited(resumeFromBackground());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopAccountChecks();
    _desktopPollTimer?.cancel();
    _desktopPollTimer = null;
    unawaited(_vpnEvents?.cancel());
    _vpnEvents = null;
    super.dispose();
  }
}

int _asInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

class _PendingTrafficBatch {
  final String id;
  final int bytes;

  const _PendingTrafficBatch({required this.id, required this.bytes});
}

Map<String, Object> _batchToJson(_PendingTrafficBatch batch) => {
  'report_id': batch.id,
  'bytes': batch.bytes,
};

_PendingTrafficBatch? _batchFromJson(dynamic value) {
  if (value is! Map) return null;
  final id = value['report_id']?.toString() ?? '';
  final bytes = _asInt(value['bytes']);
  if (id.isEmpty || bytes <= 0) return null;
  return _PendingTrafficBatch(id: id, bytes: bytes);
}
