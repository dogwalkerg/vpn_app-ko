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

  static const reportThresholdBytes = 20 * 1024 * 1024;
  static const reportInterval = Duration(minutes: 5);
  static const heartbeatInterval = Duration(seconds: 30);

  final Ref _ref;
  final CocoApi _api;
  StreamSubscription<VpnStatusEvent>? _vpnEvents;
  Timer? _heartbeatTimer;
  Timer? _batchTimer;
  Timer? _desktopPollTimer;
  Future<void> _operationTail = Future<void>.value();
  bool _disposed = false;
  bool _desktopPollBusy = false;
  bool _enforcingRestriction = false;
  int _pendingBytes = 0;
  _PendingTrafficBatch? _retryBatch;
  String? _accountKey;
  Future<void> _restoreFuture = Future<void>.value();
  DateTime _lastBatchReportAt = DateTime.now();
  String? _nativeSessionId;
  int _lastNativeUpload = 0;
  int _lastNativeDownload = 0;
  int? _lastDesktopUpload;
  int? _lastDesktopDownload;
  DateTime? _lastDesktopSampleAt;

  void _onTokenChanged(String? previous, String? token) {
    if (token == null || token.isEmpty) {
      _stopAccountChecks();
      _accountKey = null;
      _restoreFuture = Future<void>.value();
      _resetCounters(clearRestriction: true);
      return;
    }
    final accountKey = sha256.convert(utf8.encode(token)).toString();
    if (previous != token) {
      _pendingBytes = 0;
      _retryBatch = null;
      _publishPending(syncing: false);
    }
    _accountKey = accountKey;
    _restoreFuture = _restorePendingBatch(accountKey);
    _startAccountChecks();
    if (previous != token) {
      _lastBatchReportAt = DateTime.now();
      unawaited(
        _restoreFuture.then((_) async {
          if (_retryBatch != null) await flush();
          await heartbeat();
        }),
      );
    }
  }

  void _startAccountChecks() {
    _heartbeatTimer ??= Timer.periodic(
      heartbeatInterval,
      (_) => unawaited(heartbeat()),
    );
    _batchTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_onBatchTick()),
    );
  }

  Future<void> _onBatchTick() async {
    await _checkpointPending();
    if (_displayPendingBytes > 0 &&
        DateTime.now().difference(_lastBatchReportAt) >= reportInterval) {
      await flush();
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
    _lastNativeUpload = 0;
    _lastNativeDownload = 0;
    _nativeSessionId = null;
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
    unawaited(flush());
  }

  void _onVpnEvent(VpnStatusEvent event) {
    if (event.stage != VpnStage.connected ||
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
    _lastNativeUpload = uploadTotal;
    _lastNativeDownload = downloadTotal;

    _recordTraffic(
      uploadDelta: uploadDelta,
      downloadDelta: downloadDelta,
      uploadSpeed: event.uploadBytesPerSecond ?? 0,
      downloadSpeed: event.downloadBytesPerSecond ?? 0,
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
  }) {
    if (!state.connected || _enforcingRestriction) return;
    final delta = uploadDelta + downloadDelta;
    if (delta > 0) _pendingBytes += delta;
    state = state.copyWith(
      uploadBytesPerSecond: uploadSpeed,
      downloadBytesPerSecond: downloadSpeed,
      sessionUploadBytes: state.sessionUploadBytes + uploadDelta,
      sessionDownloadBytes: state.sessionDownloadBytes + downloadDelta,
      pendingBytes: _displayPendingBytes,
    );
    if (_displayPendingBytes >= reportThresholdBytes) unawaited(flush());
  }

  Future<void> _checkpointPending() {
    return _enqueue(() async {
      await _restoreFuture;
      if (!_hasToken || _retryBatch != null || _pendingBytes <= 0) return;
      final batch = _PendingTrafficBatch(
        id: const Uuid().v4(),
        bytes: _pendingBytes,
      );
      if (await _persistPendingBatch(batch)) {
        _pendingBytes = 0;
        _retryBatch = batch;
        _publishPending(syncing: false);
      }
    });
  }

  Future<void> heartbeat() async {
    await _restoreFuture;
    if (_displayPendingBytes > 0 && !await flush()) return;
    if (state.restriction != null) return;
    await _enqueue(() async {
      if (!_hasToken || _enforcingRestriction) return;
      try {
        final report = await _api.reportTraffic(0);
        await _applyReport(report);
      } catch (_) {
        // Heartbeats are retried on the next interval.
      }
    });
  }

  Future<bool> flush() async {
    if ((Platform.isWindows || Platform.isMacOS) && state.connected) {
      await _captureDesktopTrafficBeforeFlush();
    }
    var allReported = true;
    await _enqueue(() async {
      await _restoreFuture;
      if (!_hasToken || _enforcingRestriction) {
        allReported = _displayPendingBytes == 0;
        return;
      }

      while (_retryBatch != null || _pendingBytes > 0) {
        var batch = _retryBatch;
        if (batch == null) {
          batch = _PendingTrafficBatch(
            id: const Uuid().v4(),
            bytes: _pendingBytes,
          );
          if (!await _persistPendingBatch(batch)) {
            allReported = false;
            return;
          }
          _pendingBytes = 0;
          _retryBatch = batch;
        }

        _publishPending(syncing: true);
        late final CocoTrafficReport report;
        try {
          report = await _api.reportTraffic(batch.bytes, reportId: batch.id);
        } catch (_) {
          allReported = false;
          _publishPending(syncing: false);
          return;
        }

        if (!await _removePendingBatch(batch)) {
          allReported = false;
          _publishPending(syncing: false);
          return;
        }
        _retryBatch = null;
        _lastBatchReportAt = DateTime.now();
        _publishPending(syncing: true);
        try {
          await _applyReport(report);
        } finally {
          _publishPending(syncing: false);
        }
        if (report.isRestricted) return;
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

  Future<void> _applyReport(CocoTrafficReport report) async {
    if (report.hasTrafficSnapshot) {
      await _ref
          .read(subscriptionControllerProvider.notifier)
          .applyTrafficSnapshot(
            total: report.trafficTotal,
            used: report.trafficUsed,
            canUse: report.restriction == null,
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
    final retryBatch = _retryBatch;
    if (retryBatch != null) {
      await _removePendingBatch(retryBatch);
      _retryBatch = null;
    }
    _publishPending(syncing: false);
    final message = _restrictionMessage(report);
    try {
      await _ref.read(subscriptionControllerProvider.notifier).markBlocked();
      _ref.read(selectedSubscriptionNodeProvider.notifier).state = null;
      _ref.invalidate(subscriptionNodesProvider);
      state = state.copyWith(
        restriction: report.restriction,
        notice: message,
        connected: false,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      );
      try {
        await _ref.read(vpnControllerProvider.notifier).forceDisconnect();
      } catch (_) {
        state = state.copyWith(notice: '$message；代理停止失败，请手动关闭系统 VPN');
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

  int get _displayPendingBytes => _pendingBytes + (_retryBatch?.bytes ?? 0);

  String _pendingStorageKey(String accountKey) =>
      'traffic.pending.v1.$accountKey';

  Future<void> _restorePendingBatch(String accountKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingStorageKey(accountKey));
      if (_accountKey != accountKey || raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final id = data['report_id']?.toString() ?? '';
      final bytes = _asInt(data['bytes']);
      if (id.isEmpty || bytes <= 0) {
        await prefs.remove(_pendingStorageKey(accountKey));
        return;
      }
      _retryBatch = _PendingTrafficBatch(id: id, bytes: bytes);
      _publishPending(syncing: false);
    } catch (_) {
      // A later flush can still persist newly collected traffic.
    }
  }

  Future<bool> _persistPendingBatch(_PendingTrafficBatch batch) async {
    final accountKey = _accountKey;
    if (accountKey == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.setString(
        _pendingStorageKey(accountKey),
        jsonEncode({'report_id': batch.id, 'bytes': batch.bytes}),
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
      if (data is Map && data['report_id']?.toString() != batch.id) {
        return false;
      }
      return prefs.remove(key);
    } catch (_) {
      return false;
    }
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
    _nativeSessionId = null;
    _lastNativeUpload = 0;
    _lastNativeDownload = 0;
    _lastDesktopUpload = null;
    _lastDesktopDownload = null;
    _lastDesktopSampleAt = null;
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
      unawaited(flush());
    } else if (state == AppLifecycleState.resumed && _hasToken) {
      unawaited(heartbeat());
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
