// lib/features/vpn/repositories/vpn_repository_impl.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Directory,
        File,
        FileMode,
        HttpClient,
        Platform,
        Process,
        ProcessException,
        ProcessSignal,
        ProcessStartMode,
        Socket;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:vpn_app/features/vpn/mappers/vpn_mapper.dart';
import 'package:vpn_app/features/vpn/models/dto/vpn_config_dto.dart';
import 'package:vpn_app/features/vpn/models/vpn_config.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:flutter_vless/flutter_vless.dart' as ios_vless;

import '../../../core/api/api_service.dart';
import '../../../core/errors/error_mapper.dart';
import '../config/android_v2ray_config.dart';
import '../platform/vpn_channel.dart';
import '../platform/vpn_isolates.dart';
import '../platform/vpn_permissions.dart';
import '../models/subscription_node.dart';
import 'vpn_repository.dart';

class VpnRepositoryImpl implements VpnRepository {
  VpnRepositoryImpl(
    this._api, {
    required this.selectedNode,
    required this.availableNodes,
    required this.onNodeSelected,
    required this.allowNodeFallback,
    MihomoControllerClient? mihomoController,
  }) : _mihomoController = mihomoController ?? MihomoControllerClient();

  final ApiService _api;
  final SubscriptionNode? Function() selectedNode;
  final List<SubscriptionNode> Function() availableNodes;
  final void Function(SubscriptionNode) onNodeSelected;
  final bool Function() allowNodeFallback;
  final MihomoControllerClient _mihomoController;
  final VpnChannel _vpn = VpnChannel();
  FlutterV2ray? _v2ray;
  Future<void>? _androidV2rayInitialization;
  ios_vless.FlutterVless? _iosVless;
  Future<void>? _iosVlessInitialization;
  bool _iosVlessConnected = false;
  bool _iosVlessSawConnecting = false;
  Completer<void>? _iosVlessReady;
  Completer<void>? _iosVlessStopped;
  int _iosVlessTrafficSessionSequence = 0;
  String? _iosVlessTrafficSessionId;
  bool _v2rayConnected = false;
  bool _v2raySawConnecting = false;
  Completer<void>? _v2rayReady;
  Completer<void>? _v2rayStopped;
  int _v2rayTrafficSessionSequence = 0;
  String? _v2rayTrafficSessionId;
  int _v2rayStatusGeneration = 0;
  Process? _clashProcess;
  bool _clashAttached = false;
  Future<void>? _coreDownload;
  Timer? _desktopHealthTimer;
  Future<void>? _desktopHealthCheck;
  DateTime? _desktopLastProxyRepairAt;
  DateTime? _desktopLastCoreIdentityCheckAt;
  final DesktopHealthTracker _desktopHealthTracker = DesktopHealthTracker();
  int _desktopHealthGeneration = 0;
  int _desktopHealthTickCount = 0;
  Timer? _mobileHealthTimer;
  Future<void>? _mobileHealthCheck;
  int _mobileHealthGeneration = 0;
  int _mobileConsecutiveProbeFailures = 0;
  final SingleFlightVoidOperation _androidStopOperation =
      SingleFlightVoidOperation();
  final SingleFlightVoidOperation _iosStopOperation =
      SingleFlightVoidOperation();

  static const String _tunnelName = 'vpn_app_tunnel';
  static const String _bundleId = 'com.example.vpn_app';
  static const String _iosBundleId = 'app.ocelot3040.maroon4586';
  static const String _iosAppGroup = 'group.a3ccc1476ba7bbb2.1';
  static const MethodChannel _windowsSystemProxyChannel = MethodChannel(
    'osca/windows_proxy',
  );
  static const MethodChannel _macOSSystemProxyChannel = MethodChannel(
    'osca/macos_proxy',
  );
  static const String _windowsManagedCoreStopScript = r'''
$expected = [System.IO.Path]::GetFullPath('__OSCA_EXPECTED_CORE__')
$listeners = @(Get-NetTCPConnection -LocalPort 7890,9090 -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') })
if ($listeners.Count -eq 0) { exit 0 }
$pids = @($listeners.OwningProcess | Sort-Object -Unique)
if ($pids.Count -ne 1) {
  Write-Error "Refusing to stop multiple proxy listener processes"
  exit 3
}
$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($pids[0])" -ErrorAction Stop
$actual = [System.IO.Path]::GetFullPath($processInfo.ExecutablePath)
if (-not [String]::Equals($expected, $actual, [StringComparison]::OrdinalIgnoreCase)) {
  Write-Error "Refusing to stop unmanaged process $actual"
  exit 4
}
Stop-Process -Id $pids[0] -Force -ErrorAction Stop
Write-Output $pids[0]
''';

  Future<void> _ensureInitialized() async {
    await _vpn.initialize(interfaceName: _tunnelName);
    await _clearTempFiles();
  }

  Future<void> _clearTempFiles() async {
    try {
      final tmp = await getTemporaryDirectory();
      final entries = tmp.listSync().where((f) => f.path.contains('wg_'));
      for (final f in entries) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<VpnConfig> fetchConfig({CancelToken? cancelToken}) async {
    try {
      final res = await _api.get(
        '/tunnel/get-config',
        cancelToken: cancelToken,
      );
      final code = res.statusCode ?? 0;
      if (code < 200 || code >= 300) throwFromResponse(res);
      final map = (res.data as Map).cast<String, dynamic>();
      final dto = VpnConfigDto.fromJson(map);
      return vpnConfigFromDto(dto);
    } on DioException catch (e) {
      throw mapDioError(e);
    }
  }

  @override
  Future<void> connect() async {
    final node = selectedNode();
    if (node == null) throw Exception('请先选择节点');
    await _traceDesktopProxy('connect type=${node.type}');
    if (node.raw.startsWith('vless://') ||
        node.raw.startsWith('vmess://') ||
        node.raw.startsWith('trojan://') ||
        node.raw.startsWith('ss://')) {
      if (Platform.isWindows || Platform.isMacOS) {
        await _connectClash(node);
      } else if (Platform.isIOS) {
        await _connectIosWithFallback(node, allowFallback: allowNodeFallback());
      } else {
        await _connectAndroidWithFallback(
          node,
          allowFallback: allowNodeFallback(),
        );
      }
      return;
    }
    await _ensureInitialized();

    final ok = await ensureVpnPermission();
    if (!ok) throw Exception('未获得 VPN 权限');

    final cfg = await fetchConfig();
    await validateConfigIsolate(cfg);
    final wgQuick = await buildWgQuickIsolate(cfg);

    final serverAddr = _serverHostFromEndpoint(cfg.endpoint);

    const maxAttempts = 5;
    var backoff = const Duration(milliseconds: 300);
    final rnd = math.Random();
    Object? lastErr;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // На Windows даём SCM завершить удаление старого сервиса
        await _vpn.waitServiceDeleted(timeout: const Duration(seconds: 7));

        await _vpn.start(
          serverAddress: serverAddr,
          wgQuickConfig: wgQuick,
          providerBundleIdentifier: _bundleId,
        );
        return; // успех
      } catch (e) {
        lastErr = e;

        // 1) Классика SCM: 1072 / MARKED_FOR_DELETE
        if (_isMarkedForDeleteError(e)) {
          final jitterMs = 100 + rnd.nextInt(150); // 100..250
          await Future.delayed(backoff + Duration(milliseconds: jitterMs));
          backoff = Duration(
            milliseconds: (backoff.inMilliseconds * 1.8).ceil(),
          );
          continue;
        }

        // 2) Редкие транзиентные ошибки UI/кодека (не относящиеся к VPN)
        if (_looksLikeTransientUiError(e)) {
          await Future.delayed(const Duration(milliseconds: 150));
          continue;
        }

        // 3) Android: первый вызов может лишь показать системное разрешение
        if (Platform.isAndroid && attempt == 1) {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }

        rethrow;
      }
    }

    throw lastErr ?? Exception('未知 VPN 错误');
  }

  @override
  Future<void> disconnect() async {
    _cancelMobileHealthMonitor();
    if (Platform.isWindows || Platform.isMacOS) {
      _cancelDesktopHealthMonitor();
      final coreRunning =
          _clashProcess != null || _clashAttached || await _isClashRunning();
      final proxyRestoreNeeded = await _desktopSystemProxyNeedsRestore();
      await _traceDesktopProxy(
        'disconnect core=$coreRunning proxyRestoreNeeded=$proxyRestoreNeeded',
      );
      if (coreRunning || proxyRestoreNeeded) {
        final ownedProcess = _clashProcess;
        if (proxyRestoreNeeded) await _setDesktopProxy(false);
        if (coreRunning) {
          await _stopDesktopCore(ownedProcess);
        }
        _clashProcess = null;
        _clashAttached = false;
      }
    }
    if (Platform.isAndroid) {
      await _ensureAndroidV2rayInitialized();
      try {
        _handleAndroidV2rayStatus(await _v2ray!.getV2RayStatus());
      } catch (_) {}
      await _stopV2rayAndWait();
      return;
    }
    if (Platform.isIOS) {
      await _stopIosVlessAndWait();
      return;
    }
    await _vpn.stop();
  }

  @override
  Future<bool> isConnected() async {
    if (Platform.isWindows || Platform.isMacOS) {
      final proxyEnabled = await _isDesktopSystemProxyEnabled();
      await _traceDesktopProxy('isConnected proxy=$proxyEnabled');
      if (!proxyEnabled) {
        _clashAttached = false;
        if (Platform.isMacOS && await _desktopSystemProxyNeedsRestore()) {
          await _setDesktopProxy(false);
        }
      } else {
        final support = await getApplicationSupportDirectory();
        final coreName = Platform.isWindows ? 'FreedomCore.exe' : 'FreedomCore';
        final expectedCore = File(
          '${support.path}${Platform.pathSeparator}clash'
          '${Platform.pathSeparator}$coreName',
        );
        _clashAttached =
            await _isClashRunning() &&
            await _isManagedDesktopCore(expectedCore);
        if (_clashAttached && await _verifyDesktopProxy()) {
          _startDesktopHealthMonitor();
          await _traceDesktopProxy('isConnected result=desktop');
          return true;
        }
        final restoreProxy = Platform.isMacOS
            ? await _desktopSystemProxyNeedsRestore()
            : _clashAttached ||
                  !await _waitForLocalPort(
                    7890,
                    const Duration(milliseconds: 500),
                  );
        if (restoreProxy) {
          await _setDesktopProxy(false);
        }
        _clashAttached = false;
      }
    }
    if (Platform.isAndroid) {
      await _ensureAndroidV2rayInitialized();
      final status = await _v2ray!.getV2RayStatus();
      _handleAndroidV2rayStatus(status);
      if (_v2rayConnected) {
        final usable = await _verifyAndroidProxy();
        if (usable) {
          _startMobileHealthMonitor();
          return true;
        }
        await _stopV2rayAndWait();
      }
      return false;
    }
    if (Platform.isIOS) {
      await _ensureIosVlessInitialized();
      final snapshot = await _iosVless!.getTunnelSnapshot();
      _iosVlessConnected = iosTunnelSnapshotHasConnectedSystemState(snapshot);
      if (snapshot.sessionId != null) {
        _iosVlessTrafficSessionId = snapshot.sessionId;
      }
      if (_iosVlessConnected) {
        _vpn.report(
          VpnStatusEvent(
            stage: VpnStage.connected,
            uploadBytesTotal: snapshot.uploadBytes,
            downloadBytesTotal: snapshot.downloadBytes,
            sessionId: _iosVlessTrafficSessionId,
          ),
        );
        return true;
      }
      return false;
    }
    final s = await _vpn.stage();
    await _traceDesktopProxy('isConnected stage=$s');
    return s == VpnStage.connected;
  }

  Future<void> _connectV2ray(SubscriptionNode node) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台尚未安装 VLESS 原生核心');
    }
    await _ensureAndroidV2rayInitialized();
    final engine = _v2ray!;
    final parser = FlutterV2ray.parseFromURL(node.raw);
    final config = await prepareAndroidV2rayConfig(
      parser.getFullConfiguration(),
      serverHost: node.host,
    );
    final allowed = await engine.requestPermission();
    if (!allowed) throw Exception('未获得 VPN 权限');
    _v2rayReady = Completer<void>();
    _v2raySawConnecting = false;
    _v2rayTrafficSessionId =
        'android-pending-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_v2rayTrafficSessionSequence}';
    await engine.startV2Ray(
      remark: parser.remark,
      config: config,
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );
    try {
      await _v2rayReady!.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      await engine.stopV2Ray();
      _v2rayConnected = false;
      throw Exception('代理核心启动超时，请更换节点后重试');
    }
    if (!await _waitForLocalPort(10809, const Duration(seconds: 12))) {
      await engine.stopV2Ray();
      _v2rayConnected = false;
      throw Exception('代理核心已启动，但本地代理端口未就绪');
    }
    if (!await _verifyAndroidProxy()) {
      await engine.stopV2Ray();
      _v2rayConnected = false;
      throw Exception('节点已连接但无法访问互联网，请刷新订阅或更换节点');
    }
    _startMobileHealthMonitor();
  }

  Future<void> _ensureAndroidV2rayInitialized() async {
    if (!Platform.isAndroid) return;
    final engine = _v2ray ??= FlutterV2ray(
      onStatusChanged: _handleAndroidV2rayStatus,
    );
    _androidV2rayInitialization ??= engine.initializeV2Ray(
      notificationIconResourceName: 'ic_launcher2',
    );
    try {
      await _androidV2rayInitialization;
    } catch (_) {
      _androidV2rayInitialization = null;
      rethrow;
    }
  }

  void _handleAndroidV2rayStatus(V2RayStatus status) {
    final generation = status.generation;
    if (generation > 0 && generation < _v2rayStatusGeneration) return;
    if (generation > _v2rayStatusGeneration) {
      _v2rayStatusGeneration = generation;
    }
    final nativeState = status.state.toUpperCase();
    if (nativeState == 'CONNECTING') _v2raySawConnecting = true;
    _v2rayConnected = nativeState == 'CONNECTED';
    final nativeSessionId = status.sessionId.trim();
    if (nativeSessionId.isNotEmpty) {
      _v2rayTrafficSessionId = nativeSessionId;
    }
    if (nativeState == 'DISCONNECTED' &&
        !(_v2rayStopped?.isCompleted ?? true)) {
      _v2rayStopped!.complete();
    }
    if (_v2rayConnected && !(_v2rayReady?.isCompleted ?? true)) {
      _v2rayReady!.complete();
    }
    if (nativeState == 'DISCONNECTED' &&
        _v2raySawConnecting &&
        !(_v2rayReady?.isCompleted ?? true)) {
      _v2rayReady!.completeError(
        StateError(
          status.error.isEmpty ? 'Android VPN 数据通道启动失败' : status.error,
        ),
      );
    }
    if (nativeState == 'DISCONNECTED') _v2raySawConnecting = false;
    final stage = switch (nativeState) {
      'CONNECTED' => VpnStage.connected,
      'CONNECTING' => VpnStage.connecting,
      'DISCONNECTING' => VpnStage.disconnecting,
      _ => VpnStage.disconnected,
    };
    _vpn.report(
      VpnStatusEvent(
        stage: stage,
        uploadBytesPerSecond: status.uploadSpeed,
        downloadBytesPerSecond: status.downloadSpeed,
        uploadBytesTotal: status.upload,
        downloadBytesTotal: status.download,
        sessionId: _v2rayTrafficSessionId,
        reason: status.error.isEmpty ? null : status.error,
      ),
    );
  }

  Future<void> _ensureIosVlessInitialized() async {
    if (!Platform.isIOS) return;
    final engine = _iosVless ??= ios_vless.FlutterVless(
      onStatusChanged: _handleIosVlessStatus,
    );
    _iosVlessInitialization ??= engine.initializeVless(
      providerBundleIdentifier: _iosBundleId,
      groupIdentifier: _iosAppGroup,
    );
    try {
      await _iosVlessInitialization;
    } catch (_) {
      _iosVlessInitialization = null;
      rethrow;
    }
  }

  void _handleIosVlessStatus(ios_vless.VlessStatus status) {
    final state = status.state.toUpperCase();
    if (state == 'CONNECTING') _iosVlessSawConnecting = true;
    _iosVlessConnected = state == 'CONNECTED';
    final nativeSessionId = status.sessionId?.trim();
    if (nativeSessionId != null && nativeSessionId.isNotEmpty) {
      _iosVlessTrafficSessionId = nativeSessionId;
    }
    if (_iosVlessConnected && !(_iosVlessReady?.isCompleted ?? true)) {
      _iosVlessReady!.complete();
    }
    if (state == 'DISCONNECTED' && !(_iosVlessStopped?.isCompleted ?? true)) {
      _iosVlessStopped!.complete();
    }
    if (state == 'DISCONNECTED' &&
        _iosVlessSawConnecting &&
        !(_iosVlessReady?.isCompleted ?? true)) {
      _iosVlessReady!.completeError(
        StateError('iOS Packet Tunnel failed to start'),
      );
    }
    if (state == 'DISCONNECTED') _iosVlessSawConnecting = false;
    final stage = switch (state) {
      'CONNECTED' => VpnStage.connected,
      'CONNECTING' => VpnStage.connecting,
      'DISCONNECTING' => VpnStage.disconnecting,
      _ => VpnStage.disconnected,
    };
    _vpn.report(
      VpnStatusEvent(
        stage: stage,
        uploadBytesPerSecond: status.uploadSpeed,
        downloadBytesPerSecond: status.downloadSpeed,
        uploadBytesTotal: status.upload,
        downloadBytesTotal: status.download,
        sessionId: _iosVlessTrafficSessionId,
      ),
    );
  }

  Future<void> _connectIosVless(SubscriptionNode node) async {
    await _ensureIosVlessInitialized();
    final engine = _iosVless!;
    final parser = ios_vless.FlutterVless.parse(node.raw);
    final config = parser.getFullConfiguration();
    final allowed = await engine.requestPermission();
    if (!allowed) throw Exception('未获得 iOS VPN 配置权限');

    _iosVlessReady = Completer<void>();
    _iosVlessSawConnecting = false;
    _iosVlessTrafficSessionId =
        'ios-pending-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_iosVlessTrafficSessionSequence}';
    await engine.startVless(
      remark: parser.remark.isEmpty ? node.name : parser.remark,
      config: config,
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );
    try {
      await _iosVlessReady!.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      await _stopIosVlessAndWait();
      throw Exception('iOS 代理内核启动超时，请刷新订阅或更换节点');
    }
  }

  Future<void> _connectIosWithFallback(
    SubscriptionNode selected, {
    required bool allowFallback,
  }) async {
    Object? lastError;
    for (final node in connectionCandidates(
      selected: selected,
      available: availableNodes(),
      allowFallback: allowFallback,
    )) {
      try {
        await _connectIosVless(node);
        onNodeSelected(node);
        return;
      } catch (error) {
        lastError = error;
        try {
          await _stopIosVlessAndWait();
        } catch (stopError) {
          throw StateError('iOS Packet Tunnel 无法完全停止：$stopError');
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    throw lastError ?? Exception('订阅中没有可用的 iOS 节点');
  }

  Future<void> _stopIosVlessAndWait({
    Duration timeout = const Duration(seconds: 6),
  }) {
    return _iosStopOperation.run(
      () => _performStopIosVlessAndWait(timeout: timeout),
    );
  }

  Future<void> _performStopIosVlessAndWait({required Duration timeout}) async {
    final engine = _iosVless;
    if (engine == null) {
      _iosVlessConnected = false;
      return;
    }
    final shouldWait = _iosVlessConnected || _iosVlessSawConnecting;
    final stopped = Completer<void>();
    _iosVlessStopped = stopped;
    var confirmed = !shouldWait;
    try {
      await engine.stopVless().timeout(timeout + const Duration(seconds: 6));
      if (shouldWait && !stopped.isCompleted) {
        await stopped.future.timeout(timeout);
      }
      final snapshot = await engine.getTunnelSnapshot();
      confirmed = snapshot.state != 'CONNECTED' && !snapshot.running;
      if (!confirmed) {
        throw StateError('iOS Packet Tunnel 仍在运行，请稍后重试');
      }
    } finally {
      if (confirmed) {
        _iosVlessConnected = false;
        _iosVlessSawConnecting = false;
      }
      if (identical(_iosVlessStopped, stopped)) _iosVlessStopped = null;
    }
  }

  Future<void> _stopV2rayAndWait({
    Duration timeout = const Duration(seconds: 8),
  }) {
    return _androidStopOperation.run(
      () => _performStopV2rayAndWait(timeout: timeout),
    );
  }

  Future<void> _performStopV2rayAndWait({required Duration timeout}) async {
    final engine = _v2ray;
    if (engine == null) {
      _v2rayConnected = false;
      return;
    }
    final shouldWait = _v2rayConnected || _v2raySawConnecting;

    final stopped = Completer<void>();
    _v2rayStopped = stopped;
    try {
      await engine.stopV2Ray();
      if (shouldWait && !stopped.isCompleted) {
        await stopped.future.timeout(timeout);
      }
      final status = await engine.getV2RayStatus();
      final isCurrentGeneration =
          status.generation <= 0 || status.generation >= _v2rayStatusGeneration;
      _handleAndroidV2rayStatus(status);
      if (!isCurrentGeneration ||
          status.state.toUpperCase() != 'DISCONNECTED' ||
          _v2rayConnected ||
          _v2raySawConnecting) {
        throw StateError('Android VPN 服务仍在运行，请稍后重试');
      }
    } on TimeoutException {
      throw StateError('Android VPN 服务停止超时，请稍后重试');
    } finally {
      if (identical(_v2rayStopped, stopped)) {
        _v2rayStopped = null;
      }
    }
  }

  Future<void> _connectAndroidWithFallback(
    SubscriptionNode selected, {
    required bool allowFallback,
  }) async {
    Object? lastError;
    for (final node in connectionCandidates(
      selected: selected,
      available: availableNodes(),
      allowFallback: allowFallback,
      prioritizeAndroidPorts: true,
    )) {
      try {
        await _connectV2ray(node);
        onNodeSelected(node);
        return;
      } catch (error) {
        lastError = error;
        try {
          await _stopV2rayAndWait();
        } catch (stopError) {
          throw StateError('Android VPN stop confirmation failed: $stopError');
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    throw lastError ?? Exception('订阅中没有可用节点');
  }

  Future<bool> _verifyAndroidProxy() async {
    if (!Platform.isAndroid || !_v2rayConnected) return false;
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );
    (client.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () =>
        HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:10809';
    for (final url in const [
      'https://www.gstatic.com/generate_204',
      'https://cp.cloudflare.com/generate_204',
    ]) {
      try {
        final response = await client.get<void>(url);
        final status = response.statusCode ?? 0;
        if (status == 204) return true;
      } catch (_) {}
    }
    return false;
  }

  void _startMobileHealthMonitor() {
    if (!Platform.isAndroid) return;
    _cancelMobileHealthMonitor();
    final generation = _mobileHealthGeneration;
    _mobileConsecutiveProbeFailures = 0;
    _mobileHealthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_mobileHealthCheck != null) return;
      final check = _checkMobileHealth(generation);
      _mobileHealthCheck = check;
      unawaited(
        check.whenComplete(() {
          if (identical(_mobileHealthCheck, check)) {
            _mobileHealthCheck = null;
          }
        }),
      );
    });
  }

  Future<void>? _cancelMobileHealthMonitor() {
    _mobileHealthGeneration++;
    _mobileHealthTimer?.cancel();
    _mobileHealthTimer = null;
    _mobileConsecutiveProbeFailures = 0;
    return _mobileHealthCheck;
  }

  Future<void> _checkMobileHealth(int generation) async {
    if (generation != _mobileHealthGeneration || !Platform.isAndroid) return;
    await _ensureAndroidV2rayInitialized();
    final status = await _v2ray!.getV2RayStatus();
    if (generation != _mobileHealthGeneration) return;
    _handleAndroidV2rayStatus(status);
    final runtimeReady = _v2rayConnected;
    final disposition = classifyMobileHealth(
      runtimeReady: runtimeReady,
      publicReachable: runtimeReady && await _verifyAndroidProxy(),
    );
    final reason = status.error.isEmpty
        ? '当前节点已无法访问网络，请更换节点后重新连接'
        : status.error;
    if (generation != _mobileHealthGeneration) return;
    if (disposition != MobileHealthDisposition.failed) {
      _mobileConsecutiveProbeFailures = 0;
      return;
    }
    _mobileConsecutiveProbeFailures++;
    if (_mobileConsecutiveProbeFailures < 2) return;

    _cancelMobileHealthMonitor();
    try {
      await _stopV2rayAndWait();
    } catch (_) {}
    _vpn.report(VpnStatusEvent(stage: VpnStage.disconnected, reason: reason));
  }

  Future<bool> _waitForLocalPort(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 500),
        );
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 200));
      } finally {
        socket?.destroy();
      }
    }
    return false;
  }

  Future<void> _connectClash(SubscriptionNode node) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}clash',
    );
    await directory.create(recursive: true);

    final nodes = availableNodes();
    final yaml = _buildMihomoConfig(nodes);
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.yaml',
    );
    await config.writeAsString(yaml, flush: true);

    final coreName = Platform.isWindows ? 'FreedomCore.exe' : 'FreedomCore';
    final core = File('${directory.path}${Platform.pathSeparator}$coreName');
    final expectedNodeNames = mihomoCoreNodes(
      nodes,
    ).map((item) => item.coreName).toSet();
    final fallbackAllowed = allowNodeFallback();

    final existingCore = await _isClashRunning();
    await _traceDesktopProxy('connectClash existingCore=$existingCore');
    if (existingCore) {
      if (!await _isManagedDesktopCore(core)) {
        throw Exception('本地 9090 端口已被其他代理核心占用，请先退出其他代理软件');
      }
      try {
        await _reloadClashConfig(config, expectedNodeNames);
        final attached = await _selectUsableClashNode(
          node,
          allowFallback: fallbackAllowed,
        );
        if (attached) {
          await _setDesktopProxy(true);
          _clashAttached = true;
          _startDesktopHealthMonitor();
          _vpn.report(VpnStatusEvent(stage: VpnStage.connected));
          return;
        }
      } catch (error) {
        await _traceDesktopProxy('reload existing core failed: $error');
      }
      await disconnect();
    }

    await _ensureDesktopCore(core);
    if (Platform.isMacOS) await Process.run('chmod', ['+x', core.path]);

    try {
      final process = await Process.start(core.path, [
        '-d',
        directory.path,
        '-ext-ctl',
        '127.0.0.1:9090',
      ], mode: ProcessStartMode.detachedWithStdio);
      _clashProcess = process;
      unawaited(process.stdout.drain<void>().catchError((_) {}));
      unawaited(process.stderr.drain<void>().catchError((_) {}));
      if (!await _waitForClashRunning()) {
        throw Exception('代理核心启动超时，请稍后重试');
      }
      if (!await _isManagedDesktopCore(core, expectedPid: process.pid)) {
        throw Exception('代理核心端口身份校验失败，请退出其他代理软件后重试');
      }
      if (!await _selectUsableClashNode(node, allowFallback: fallbackAllowed)) {
        throw Exception(
          fallbackAllowed
              ? '订阅中的候选节点均无法访问网络，请刷新订阅后重试'
              : '所选节点当前无法访问网络，请保持当前选择并稍后重试或手动更换节点',
        );
      }
      await _setDesktopProxy(true);
      _clashAttached = true;
      _startDesktopHealthMonitor();
      _vpn.report(VpnStatusEvent(stage: VpnStage.connected));
    } catch (error) {
      await _traceDesktopProxy('new core connection failed: $error');
      try {
        await disconnect();
      } catch (cleanupError) {
        await _traceDesktopProxy('new core cleanup failed: $cleanupError');
      }
      rethrow;
    }
  }

  String _buildMihomoConfig(List<SubscriptionNode> nodes) {
    final vlessNodes = mihomoCoreNodes(nodes);
    if (vlessNodes.isEmpty) throw Exception('订阅中没有兼容的 VLESS 节点');

    String quoted(String value) => jsonEncode(value);
    final buffer = StringBuffer()
      ..writeln('mixed-port: 7890')
      ..writeln('allow-lan: false')
      ..writeln('mode: rule')
      ..writeln('log-level: info')
      ..writeln('proxies:');
    for (final item in vlessNodes) {
      final node = item.node;
      final uri = Uri.parse(node.raw);
      final query = uri.queryParameters;
      final sni = query['sni'] ?? query['host'] ?? uri.host;
      final host = query['host'] ?? sni;
      final path = query['path'] ?? '/';
      final network = query['type'] ?? 'tcp';
      buffer
        ..writeln('  - name: ${quoted(item.coreName)}')
        ..writeln('    type: vless')
        ..writeln('    server: ${quoted(uri.host)}')
        ..writeln('    port: ${uri.port}')
        ..writeln('    uuid: ${quoted(uri.userInfo)}')
        ..writeln('    udp: true')
        ..writeln('    tls: ${query['security'] == 'tls'}')
        ..writeln('    servername: ${quoted(sni)}')
        ..writeln('    client-fingerprint: ${quoted(query['fp'] ?? 'chrome')}')
        ..writeln('    network: $network');
      final flow = query['flow'];
      if (flow != null && flow.isNotEmpty) {
        buffer.writeln('    flow: ${quoted(flow)}');
      }
      if (network == 'ws') {
        buffer
          ..writeln('    ws-opts:')
          ..writeln('      path: ${quoted(path)}')
          ..writeln('      headers:')
          ..writeln('        Host: ${quoted(host)}');
      }
    }
    buffer
      ..writeln('proxy-groups:')
      ..writeln('  - name: Proxy')
      ..writeln('    type: select')
      ..writeln('    proxies:');
    for (final item in vlessNodes) {
      buffer.writeln('      - ${quoted(item.coreName)}');
    }
    buffer
      ..writeln('rules:')
      ..writeln('  - MATCH,Proxy');
    return buffer.toString();
  }

  Future<bool> _selectUsableClashNode(
    SubscriptionNode selected, {
    required bool allowFallback,
  }) async {
    Object? lastError;
    for (final node in connectionCandidates(
      selected: selected,
      available: availableNodes(),
      allowFallback: allowFallback,
    )) {
      try {
        await _selectClashNode(node);
        if (await _verifyDesktopProxy()) {
          onNodeSelected(node);
          return true;
        }
      } catch (error) {
        lastError = error;
        if (!allowFallback) rethrow;
      }
    }
    if (lastError != null && !allowFallback) throw lastError;
    return false;
  }

  Future<bool> _isClashRunning() async {
    if (!Platform.isWindows && !Platform.isMacOS) return false;
    return _mihomoController.isRunning();
  }

  void _startDesktopHealthMonitor() {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    _cancelDesktopHealthMonitor();
    final generation = _desktopHealthGeneration;
    _desktopLastProxyRepairAt = null;
    _desktopLastCoreIdentityCheckAt = null;
    _desktopHealthTracker.reset();
    _desktopHealthTickCount = 0;
    _desktopHealthTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _scheduleDesktopHealthCheck(generation);
    });
    unawaited(
      _traceDesktopProxy('health monitor started generation=$generation'),
    );
  }

  void _cancelDesktopHealthMonitor() {
    _desktopHealthGeneration++;
    _desktopHealthTimer?.cancel();
    _desktopHealthTimer = null;
    _desktopLastProxyRepairAt = null;
    _desktopLastCoreIdentityCheckAt = null;
    _desktopHealthTracker.reset();
  }

  void _scheduleDesktopHealthCheck(int generation) {
    if (_desktopHealthCheck != null) return;
    final check = _checkDesktopHealth(generation);
    _desktopHealthCheck = check;
    unawaited(
      check.whenComplete(() {
        if (identical(_desktopHealthCheck, check)) {
          _desktopHealthCheck = null;
        }
      }),
    );
  }

  Future<void> _checkDesktopHealth(int generation) async {
    if (generation != _desktopHealthGeneration || !_clashAttached) {
      return;
    }
    try {
      final traceTick = _desktopHealthTickCount < 3;
      if (traceTick) {
        _desktopHealthTickCount++;
        await _traceDesktopProxy(
          'health tick=$_desktopHealthTickCount generation=$generation',
        );
      }
      final controllerRunning = await _isClashRunning();
      final mixedPortReady =
          controllerRunning &&
          await _waitForLocalPort(7890, const Duration(milliseconds: 800));
      if (generation != _desktopHealthGeneration) return;
      if (traceTick) {
        await _traceDesktopProxy(
          'health core=$controllerRunning port=$mixedPortReady',
        );
      }
      final localHealth = _desktopHealthTracker.recordLocalAvailability(
        controllerRunning && mixedPortReady,
      );
      if (localHealth != DesktopHealthDisposition.healthy) {
        _desktopLastCoreIdentityCheckAt = null;
        await _traceDesktopProxy(
          'health local degraded '
          'count=${_desktopHealthTracker.localFailureCount} '
          'threshold=${_desktopHealthTracker.localFailureThreshold} '
          'controller=$controllerRunning port=$mixedPortReady',
        );
        if (localHealth == DesktopHealthDisposition.failed &&
            generation == _desktopHealthGeneration) {
          await _failDesktopHealth(generation, '代理核心已意外退出，请重新连接');
          return;
        }
      }
      if (generation != _desktopHealthGeneration) return;

      final now = DateTime.now();
      final lastIdentityCheck = _desktopLastCoreIdentityCheckAt;
      if (localHealth == DesktopHealthDisposition.healthy &&
          (lastIdentityCheck == null ||
              now.difference(lastIdentityCheck) >=
                  const Duration(seconds: 15))) {
        final support = await getApplicationSupportDirectory();
        final expectedCore = File(
          '${support.path}${Platform.pathSeparator}clash'
          '${Platform.pathSeparator}'
          '${Platform.isWindows ? 'FreedomCore.exe' : 'FreedomCore'}',
        );
        final managed = await _isManagedDesktopCore(expectedCore);
        if (generation != _desktopHealthGeneration) return;
        if (!managed) {
          await _failDesktopHealth(generation, '代理核心身份校验失败，请退出其他代理软件后重新连接');
          return;
        }
        _desktopLastCoreIdentityCheckAt = now;
        final exitReady = await _verifyDesktopProxy();
        if (generation != _desktopHealthGeneration) return;
        final upstreamWasDegraded =
            _desktopHealthTracker.upstreamFailureCount > 0;
        final upstreamHealth = _desktopHealthTracker.recordUpstreamReachability(
          exitReady,
        );
        if (!exitReady) {
          await _traceDesktopProxy(
            'health upstream degraded '
            'count=${_desktopHealthTracker.upstreamFailureCount}; '
            'retaining core and system proxy',
          );
        } else if (upstreamWasDegraded &&
            upstreamHealth == DesktopHealthDisposition.healthy) {
          await _traceDesktopProxy('health upstream recovered');
        }
      }

      final proxy = await _readDesktopProxyState();
      if (generation != _desktopHealthGeneration) return;
      if (traceTick) {
        final rawEnable = proxy.enableOutput.replaceAll(
          RegExp(r'[\r\n]+'),
          ' | ',
        );
        await _traceDesktopProxy(
          'health proxy enabled=${proxy.enabled} local=${proxy.usesLocalCore}'
          ' raw=[$rawEnable]',
        );
      }
      if (proxy.enabled && proxy.usesLocalCore) return;
      await _traceDesktopProxy(
        'health mismatch enabled=${proxy.enabled} local=${proxy.usesLocalCore}',
      );
      if (!proxy.usesLocalCore) {
        await _failDesktopHealth(generation, '系统代理已被其他软件接管，请先退出其他代理软件后重新连接');
        return;
      }

      final previousRepair = _desktopLastProxyRepairAt;
      if (previousRepair != null &&
          now.difference(previousRepair) < const Duration(seconds: 15)) {
        await _failDesktopHealth(generation, '系统代理被其他软件反复修改，请先退出其他代理软件后重新连接');
        return;
      }

      final support = await getApplicationSupportDirectory();
      final expectedCore = File(
        '${support.path}${Platform.pathSeparator}clash'
        '${Platform.pathSeparator}'
        '${Platform.isWindows ? 'FreedomCore.exe' : 'FreedomCore'}',
      );
      final managed = await _isManagedDesktopCore(expectedCore);
      if (generation != _desktopHealthGeneration) return;
      if (!managed) {
        if (generation == _desktopHealthGeneration) {
          await _failDesktopHealth(generation, '代理核心身份校验失败，请退出其他代理软件后重新连接');
        }
        return;
      }

      _desktopLastProxyRepairAt = now;
      await _traceDesktopProxy('health monitor repairing system proxy');
      if (generation != _desktopHealthGeneration) return;
      await _setDesktopProxy(true);
      if (generation != _desktopHealthGeneration) return;
      await Future.delayed(const Duration(milliseconds: 300));
      if (generation != _desktopHealthGeneration) return;
      final repaired = await _readDesktopProxyState();
      if (!repaired.enabled || !repaired.usesLocalCore) {
        await _failDesktopHealth(generation, '系统代理恢复失败，请退出其他代理软件后重新连接');
      }
    } catch (error) {
      if (generation == _desktopHealthGeneration) {
        await _traceDesktopProxy('health monitor failed: $error');
        await _failDesktopHealth(generation, '系统代理检查失败，请重新连接');
      }
    }
  }

  Future<void> _failDesktopHealth(int generation, String reason) async {
    if (generation != _desktopHealthGeneration) return;
    _cancelDesktopHealthMonitor();
    final failureGeneration = _desktopHealthGeneration;
    await _traceDesktopProxy('health monitor disconnect: $reason');
    if (failureGeneration != _desktopHealthGeneration) return;
    Object? proxyRestoreError;
    try {
      final proxyRestoreNeeded = await _desktopSystemProxyNeedsRestore();
      if (failureGeneration != _desktopHealthGeneration) return;
      if (proxyRestoreNeeded) {
        await _setDesktopProxy(false);
      }
    } catch (error) {
      proxyRestoreError = error;
      await _traceDesktopProxy(
        'health monitor kept core after proxy restore failed: $error',
      );
    }
    if (failureGeneration != _desktopHealthGeneration) return;
    if (proxyRestoreError != null) {
      final coreStillRunning = await _isClashRunning();
      if (failureGeneration != _desktopHealthGeneration) return;
      if (coreStillRunning) {
        _clashAttached = true;
        _vpn.report(
          VpnStatusEvent(
            stage: VpnStage.connected,
            reason: '系统代理包含用户修改，已保留代理核心以避免断网',
          ),
        );
      } else {
        _clashProcess = null;
        _clashAttached = false;
        _vpn.report(
          VpnStatusEvent(stage: VpnStage.disconnected, reason: reason),
        );
      }
      return;
    }
    final ownedProcess = _clashProcess;
    try {
      final coreRunning = ownedProcess != null || await _isClashRunning();
      if (failureGeneration != _desktopHealthGeneration) return;
      if (coreRunning) {
        await _stopDesktopCore(ownedProcess);
      }
    } catch (error) {
      await _traceDesktopProxy('health monitor core stop failed: $error');
    }
    if (failureGeneration != _desktopHealthGeneration) return;
    _clashProcess = null;
    _clashAttached = false;
    _vpn.report(VpnStatusEvent(stage: VpnStage.disconnected, reason: reason));
  }

  Future<bool> _waitForClashRunning({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isClashRunning()) return true;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  Future<void> _reloadClashConfig(
    File config,
    Set<String> expectedNodeNames,
  ) async {
    await _mihomoController.reloadConfig(config.path);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    do {
      final actualNodeNames = await _mihomoController.proxyGroupNodeNames();
      if (clashNodeSetsMatch(expectedNodeNames, actualNodeNames)) return;
      await Future.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    throw StateError('代理核心未加载当前订阅配置');
  }

  Future<bool> _isManagedDesktopCore(
    File expectedCore, {
    int? expectedPid,
  }) async {
    if (Platform.isWindows) {
      final valid =
          await _windowsSystemProxyChannel.invokeMethod<bool>('validateCore', {
            'path': expectedCore.path,
            if (expectedPid != null) 'pid': expectedPid,
          }) ??
          false;
      await _traceDesktopProxy(
        'managed core lookup valid=$valid expectedPid=$expectedPid',
      );
      return valid;
    }
    if (Platform.isMacOS) {
      final state = await _macOSSystemProxyChannel
          .invokeMapMethod<String, dynamic>('validateCore', {
            'path': expectedCore.path,
            if (expectedPid != null) 'pid': expectedPid,
          });
      return state?['valid'] == true;
    }
    return false;
  }

  Future<void> _stopDesktopCore(Process? ownedProcess) async {
    if (ownedProcess != null) {
      ownedProcess.kill(ProcessSignal.sigterm);
      if (await _waitForClashStopped(timeout: const Duration(seconds: 2))) {
        return;
      }
    }

    final support = await getApplicationSupportDirectory();
    final coreName = Platform.isWindows ? 'FreedomCore.exe' : 'FreedomCore';
    final expectedCore = File(
      '${support.path}${Platform.pathSeparator}clash'
      '${Platform.pathSeparator}$coreName',
    );
    if (Platform.isWindows) {
      final result = await _runWindowsCommand('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        encodePowerShellCommand(
          _windowsCoreScript(_windowsManagedCoreStopScript, expectedCore),
        ),
      ], timeout: const Duration(seconds: 5));
      await _traceDesktopProxy(
        'managed core stop exit=${result.exitCode} ${result.details}',
      );
      if (result.exitCode != 0 && await _isClashRunning()) {
        throw StateError('无法安全停止代理核心：${result.details}');
      }
    } else if (Platform.isMacOS) {
      final pid = await _managedMacCorePid(expectedCore);
      if (pid == null && await _isClashRunning()) {
        throw StateError('无法确认正在运行的代理核心身份');
      }
      if (pid != null) Process.killPid(pid, ProcessSignal.sigterm);
    }

    if (!await _waitForClashStopped()) {
      throw StateError('代理核心停止超时，请退出其他代理软件后重试');
    }
  }

  Future<int?> _managedMacCorePid(File expectedCore) async {
    final state = await _macOSSystemProxyChannel
        .invokeMapMethod<String, dynamic>('validateCore', {
          'path': expectedCore.path,
        });
    if (state?['valid'] != true) return null;
    final value = state?['pid'];
    return value is int ? value : int.tryParse(value?.toString() ?? '');
  }

  String _windowsCoreScript(String template, File expectedCore) {
    final escapedPath = expectedCore.path.replaceAll("'", "''");
    return template.replaceFirst('__OSCA_EXPECTED_CORE__', escapedPath);
  }

  Future<bool> _isDesktopSystemProxyEnabled() async {
    if (Platform.isWindows) return _isWindowsSystemProxyEnabled();
    if (Platform.isMacOS) return _isMacSystemProxyEnabled();
    return false;
  }

  Future<
    ({
      bool enabled,
      bool usesLocalCore,
      String enableOutput,
      String serverOutput,
    })
  >
  _readDesktopProxyState() {
    if (Platform.isWindows) return _readWindowsProxyState();
    if (Platform.isMacOS) return _readMacSystemProxyState();
    throw UnsupportedError('Desktop system proxy is not supported');
  }

  Future<bool> _desktopSystemProxyNeedsRestore() async {
    if (Platform.isWindows) {
      return (await _readWindowsProxyState()).usesLocalCore;
    }
    if (Platform.isMacOS) {
      final state = await _macOSSystemProxyChannel
          .invokeMapMethod<String, dynamic>('read');
      if (state == null) {
        throw StateError('macOS returned an empty system proxy state');
      }
      return macOSProxyNeedsRestore(
        usesLocalCore: state['usesLocalCore'] == true,
        snapshotAvailable: state['snapshotAvailable'] == true,
      );
    }
    return false;
  }

  Future<bool> _isWindowsSystemProxyEnabled() async {
    final state = await _readWindowsProxyState();
    return state.enabled && state.usesLocalCore;
  }

  Future<
    ({
      bool enabled,
      bool usesLocalCore,
      String enableOutput,
      String serverOutput,
    })
  >
  _readWindowsProxyState() async {
    try {
      final state = await _windowsSystemProxyChannel
          .invokeMapMethod<String, dynamic>('read');
      return _windowsProxyStateFromChannel(state);
    } catch (error) {
      await _traceDesktopProxy('WinINet proxy query failed: $error');
      rethrow;
    }
  }

  ({bool enabled, bool usesLocalCore, String enableOutput, String serverOutput})
  _windowsProxyStateFromChannel(Map<String, dynamic>? state) {
    if (state == null) {
      throw StateError('Windows returned an empty system proxy state');
    }
    final enabled = state['enabled'] == true;
    final server = state['server']?.toString() ?? '';
    final flags = state['flags'];
    return (
      enabled: enabled,
      usesLocalCore: windowsProxyServerUsesLocalCore(server),
      enableOutput: 'WinINet flags=$flags enabled=$enabled',
      serverOutput: 'WinINet server=$server',
    );
  }

  Future<bool> _isMacSystemProxyEnabled() async {
    final state = await _readMacSystemProxyState();
    return state.enabled && state.usesLocalCore;
  }

  Future<
    ({
      bool enabled,
      bool usesLocalCore,
      String enableOutput,
      String serverOutput,
    })
  >
  _readMacSystemProxyState() async {
    final state = await _macOSSystemProxyChannel
        .invokeMapMethod<String, dynamic>('read');
    if (state == null) {
      throw StateError('macOS returned an empty system proxy state');
    }
    final enabled = state['enabled'] == true;
    final usesLocalCore = state['usesLocalCore'] == true;
    final server = state['server']?.toString() ?? '';
    final activeService = state['activeServiceId']?.toString() ?? '';
    return (
      enabled: enabled,
      usesLocalCore: usesLocalCore,
      enableOutput: 'macOS enabled=$enabled activeService=$activeService',
      serverOutput: 'macOS server=$server',
    );
  }

  Future<bool> _waitForClashStopped({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _isClashRunning()) return true;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return !await _isClashRunning();
  }

  Future<void> _selectClashNode(SubscriptionNode node) async {
    final matches = mihomoCoreNodes(
      availableNodes(),
    ).where((item) => item.node.raw == node.raw);
    if (matches.isEmpty) {
      throw StateError('所选节点已不在当前订阅中，请刷新线路');
    }
    await _mihomoController.selectNode(matches.first.coreName);
  }

  Future<bool> _verifyDesktopProxy() async {
    if (!Platform.isWindows && !Platform.isMacOS) return false;
    Process? process;
    try {
      process = await Process.start(
        Platform.isWindows ? 'curl.exe' : '/usr/bin/curl',
        [
          '--silent',
          '--show-error',
          '--max-time',
          '10',
          '--noproxy',
          '',
          '--proxy',
          'http://127.0.0.1:7890',
          '--output',
          Platform.isWindows ? 'NUL' : '/dev/null',
          '--write-out',
          '%{http_code}',
          'https://www.gstatic.com/generate_204',
        ],
      );
      final output = process.stdout.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          process?.kill();
          return -1;
        },
      );
      final statusCode = int.tryParse((await output).trim());
      return exitCode == 0 && statusCode == 204;
    } catch (_) {
      process?.kill();
      return false;
    }
  }

  Future<({String url, String sha256})> _desktopCoreInfo() async {
    if (Platform.isWindows) {
      return (
        url: 'https://r2.xsh.ccwu.cc/vpn-cores/windows/Clash-Coco.exe',
        sha256:
            '58a8136fdb87d4eee7e3518041b0769cc5e673a7ca98dfc030f99a47ff49588f',
      );
    }
    final result = await Process.run('uname', ['-m']);
    final arm = result.stdout.toString().trim().contains('arm64');
    return arm
        ? (
            url: 'https://r2.xsh.ccwu.cc/vpn-cores/macos-arm64/Clash-Coco',
            sha256:
                'f60287548ee629a2cc6dce24d7dc654d7d3b6c37fe3ecdd43e897760707b33ec',
          )
        : (
            url: 'https://r2.xsh.ccwu.cc/vpn-cores/macos-x64/Clash-Coco',
            sha256:
                '06697ede7893eba69388114045b365ff465bfbd4213b77a3880d99266705dfab',
          );
  }

  Future<void> _ensureDesktopCore(File core) async {
    final active = _coreDownload;
    if (active != null) return active;
    final future = _downloadDesktopCoreIfNeeded(core);
    _coreDownload = future;
    try {
      await future;
    } finally {
      _coreDownload = null;
    }
  }

  Future<void> _downloadDesktopCoreIfNeeded(File core) async {
    final info = await _desktopCoreInfo();
    if (await core.exists() && await _fileSha256(core) == info.sha256) return;

    final partial = File(
      '${core.path}.download.${DateTime.now().microsecondsSinceEpoch}',
    );
    await Dio().download(info.url, partial.path);
    final actual = await _fileSha256(partial);
    if (actual != info.sha256) {
      await partial.delete();
      throw Exception('代理核心校验失败');
    }
    if (await core.exists()) {
      if (await _fileSha256(core) == info.sha256) {
        await partial.delete();
        return;
      }
      await core.delete();
    }
    await partial.rename(core.path);
  }

  Future<String> _fileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _setDesktopProxy(bool enabled) async {
    if (Platform.isWindows) {
      await _traceDesktopProxy('setProxy requested=$enabled');
      final state = await _windowsSystemProxyChannel
          .invokeMapMethod<String, dynamic>('apply', {'enabled': enabled});
      final proxy = _windowsProxyStateFromChannel(state);
      final applied = enabled
          ? proxy.enabled && proxy.usesLocalCore
          : !proxy.enabled || !proxy.usesLocalCore;
      if (!applied) {
        throw Exception(
          enabled
              ? 'Windows system proxy did not enable on 127.0.0.1:7890'
              : 'Windows system proxy did not disable',
        );
      }
      await _traceDesktopProxy(
        'setProxy verified=${proxy.enabled} endpoint=${proxy.usesLocalCore}',
      );
      return;
    }
    if (Platform.isMacOS) {
      await _setMacSystemProxy(enabled);
      return;
    }
  }

  Future<void> _setMacSystemProxy(bool enabled) async {
    final state = await _macOSSystemProxyChannel
        .invokeMapMethod<String, dynamic>('apply', {
          'enabled': enabled,
          if (enabled) 'host': '127.0.0.1',
          if (enabled) 'port': 7890,
        });
    if (state == null) {
      throw StateError('macOS returned an empty system proxy result');
    }
    if (enabled) {
      if (state['enabled'] != true || state['usesLocalCore'] != true) {
        throw StateError('macOS system proxy did not enable on 127.0.0.1:7890');
      }
      return;
    }
    final conflicts =
        (state['conflicts'] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final restored = state['restored'] == true;
    final usesLocalCore = state['usesLocalCore'] == true;
    if (!macOSProxyRestoreSucceeded(
      restored: restored,
      usesLocalCore: usesLocalCore,
      conflicts: conflicts,
    )) {
      final details = conflicts.isEmpty ? '' : ': ${conflicts.join(', ')}';
      throw StateError('macOS system proxy could not be restored$details');
    }
  }

  Future<({int exitCode, String stdout, String details})> _runWindowsCommand(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final process = await Process.start(executable, arguments);
      final stdoutFuture = process.stdout
          .transform(utf8.decoder)
          .join()
          .catchError((_) => '');
      final stderrFuture = process.stderr
          .transform(utf8.decoder)
          .join()
          .catchError((_) => '');
      var exitCode = -1;
      var timedOut = false;
      try {
        exitCode = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        timedOut = true;
        process.kill(ProcessSignal.sigterm);
      }
      final output = await Future.wait([
        stdoutFuture,
        stderrFuture,
      ]).timeout(const Duration(milliseconds: 500), onTimeout: () => ['', '']);
      final stdout = output[0].trim();
      final stderr = output[1].trim();
      final details = timedOut
          ? 'timed out after ${timeout.inMilliseconds} ms'
          : stderr.isNotEmpty
          ? stderr
          : stdout.isNotEmpty
          ? stdout
          : 'exit code $exitCode';
      return (
        exitCode: timedOut ? -1 : exitCode,
        stdout: stdout,
        details: details,
      );
    } on ProcessException catch (error) {
      return (exitCode: -1, stdout: '', details: error.message);
    }
  }

  Future<void> _traceDesktopProxy(String message) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    try {
      final support = await getApplicationSupportDirectory();
      final file = File(
        '${support.path}${Platform.pathSeparator}clash'
        '${Platform.pathSeparator}proxy-events.log',
      );
      await file.parent.create(recursive: true);
      if (await file.exists() && await file.length() > 64 * 1024) {
        await file.writeAsString('');
      }
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  void dispose() {
    unawaited(_traceDesktopProxy('repository disposed'));
    _cancelDesktopHealthMonitor();
    _cancelMobileHealthMonitor();
  }

  // --- helpers ---------------------------------------------------------------

  bool _isMarkedForDeleteError(Object e) {
    final s = e.toString();
    return s.contains('1072') ||
        s.contains('ERROR_SERVICE_MARKED_FOR_DELETE') ||
        s.toLowerCase().contains('marked for delete') ||
        (s.toLowerCase().contains('sid') && s.contains('1072'));
  }

  /// Иногда в логах прилетает ошибка декодера изображений (например GIF),
  /// не относящаяся к запуску туннеля. Считаем её транзиентной и пробуем заново.
  bool _looksLikeTransientUiError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('missing extension byte') || // gif decoder
        s.contains('image codec') ||
        s.contains('codec failed');
  }

  /// Приводим endpoint к ожидаемому serverAddress (только хост без порта/схемы).
  String _serverHostFromEndpoint(String endpoint) {
    final e = endpoint.trim();

    // [IPv6]:port
    if (e.startsWith('[')) {
      final close = e.indexOf(']');
      if (close > 0) return e.substring(1, close);
    }

    // scheme://host:port
    final uri = Uri.tryParse(e);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }

    // host:port
    final lastColon = e.lastIndexOf(':');
    if (lastColon > -1 && !e.contains('://')) {
      return e.substring(0, lastColon);
    }

    return e;
  }
}

enum DesktopHealthDisposition { healthy, degraded, failed }

class DesktopHealthTracker {
  DesktopHealthTracker({this.localFailureThreshold = 3})
    : assert(localFailureThreshold > 0);

  final int localFailureThreshold;
  int _localFailureCount = 0;
  int _upstreamFailureCount = 0;

  int get localFailureCount => _localFailureCount;
  int get upstreamFailureCount => _upstreamFailureCount;

  DesktopHealthDisposition recordLocalAvailability(bool available) {
    if (available) {
      _localFailureCount = 0;
      return DesktopHealthDisposition.healthy;
    }
    _localFailureCount++;
    return _localFailureCount >= localFailureThreshold
        ? DesktopHealthDisposition.failed
        : DesktopHealthDisposition.degraded;
  }

  DesktopHealthDisposition recordUpstreamReachability(bool reachable) {
    if (reachable) {
      _upstreamFailureCount = 0;
      return DesktopHealthDisposition.healthy;
    }
    _upstreamFailureCount++;
    return DesktopHealthDisposition.degraded;
  }

  void reset() {
    _localFailureCount = 0;
    _upstreamFailureCount = 0;
  }
}

class SingleFlightVoidOperation {
  Future<void>? _active;

  Future<void> run(Future<void> Function() operation) {
    final active = _active;
    if (active != null) return active;

    late final Future<void> future;
    future = Future<void>.sync(operation).whenComplete(() {
      if (identical(_active, future)) _active = null;
    });
    _active = future;
    return future;
  }
}

class MihomoControllerClient {
  MihomoControllerClient({String baseUrl = 'http://127.0.0.1:9090', Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(milliseconds: 800),
              receiveTimeout: const Duration(milliseconds: 800),
              sendTimeout: const Duration(milliseconds: 800),
            ),
          );

  final Dio _dio;

  Future<bool> isRunning() async {
    try {
      final response = await _dio.get<dynamic>('/configs');
      return _isSuccessful(response.statusCode);
    } catch (_) {
      return false;
    }
  }

  Future<void> reloadConfig(String path) async {
    final response = await _dio.put<dynamic>(
      '/configs',
      queryParameters: const {'force': true},
      data: {'path': path},
    );
    _requireSuccess(response, 'reload config');
  }

  Future<Set<String>> proxyGroupNodeNames() async {
    final response = await _dio.get<dynamic>('/proxies/Proxy');
    _requireSuccess(response, 'read proxy group');
    final data = response.data;
    if (data is! Map || data['all'] is! List) {
      throw const FormatException('Invalid Mihomo Proxy group response');
    }
    return (data['all'] as List).whereType<String>().toSet();
  }

  Future<void> selectNode(String name) async {
    final response = await _dio.put<dynamic>(
      '/proxies/Proxy',
      data: {'name': name},
    );
    _requireSuccess(response, 'select node');
  }

  bool _isSuccessful(int? statusCode) =>
      statusCode != null && statusCode >= 200 && statusCode < 300;

  void _requireSuccess(Response<dynamic> response, String operation) {
    if (!_isSuccessful(response.statusCode)) {
      throw StateError(
        'Mihomo $operation failed with HTTP ${response.statusCode}',
      );
    }
  }
}

List<({SubscriptionNode node, String coreName})> mihomoCoreNodes(
  List<SubscriptionNode> nodes,
) {
  final seenUris = <String>{};
  final result = <({SubscriptionNode node, String coreName})>[];
  for (final node in nodes) {
    if (!node.raw.toLowerCase().startsWith('vless://') ||
        !seenUris.add(node.raw)) {
      continue;
    }
    final displayName = node.name.trim().isEmpty ? 'Node' : node.name.trim();
    final identity = sha256
        .convert(utf8.encode(node.raw))
        .toString()
        .substring(0, 12);
    result.add((node: node, coreName: '$displayName [$identity]'));
  }
  return result;
}

List<SubscriptionNode> connectionCandidates({
  required SubscriptionNode selected,
  required List<SubscriptionNode> available,
  required bool allowFallback,
  bool prioritizeAndroidPorts = false,
  int limit = 8,
}) {
  if (!allowFallback || limit <= 1) return [selected];

  final alternatives = available
      .where((node) => node.raw != selected.raw)
      .toList();
  if (prioritizeAndroidPorts) {
    final originalOrder = <String, int>{
      for (var index = 0; index < alternatives.length; index++)
        alternatives[index].raw: index,
    };
    alternatives.sort((a, b) {
      final byPort = _androidPortPriority(
        a.port,
      ).compareTo(_androidPortPriority(b.port));
      if (byPort != 0) return byPort;
      return (originalOrder[a.raw] ?? 0).compareTo(originalOrder[b.raw] ?? 0);
    });
  }
  return [selected, ...alternatives.take(limit - 1)];
}

int _androidPortPriority(int port) => switch (port) {
  2096 => 0,
  443 => 1,
  2053 || 2083 || 2087 => 2,
  _ => 3,
};

bool clashNodeSetsMatch(Iterable<String> expected, Iterable<String> actual) {
  final expectedSet = expected.toSet();
  final actualSet = actual.toSet();
  return expectedSet.length == actualSet.length &&
      expectedSet.every(actualSet.contains);
}

bool desktopCorePathsMatch(String expected, String actual) {
  String normalize(String value) => value
      .trim()
      .replaceAll('/', Platform.pathSeparator)
      .replaceAll('\\', Platform.pathSeparator)
      .toLowerCase();
  return normalize(expected) == normalize(actual);
}

String encodePowerShellCommand(String script) {
  final bytes = <int>[];
  for (final codeUnit in script.codeUnits) {
    bytes
      ..add(codeUnit & 0xff)
      ..add((codeUnit >> 8) & 0xff);
  }
  return base64Encode(bytes);
}

bool windowsProxyServerUsesLocalCore(String proxyServer) {
  final registryValue = RegExp(
    r'ProxyServer\s+REG_SZ\s+([^\r\n]+)',
    caseSensitive: false,
  ).firstMatch(proxyServer)?.group(1);
  final server = (registryValue ?? proxyServer).trim().toLowerCase().replaceAll(
    ' ',
    '',
  );
  if (server == '127.0.0.1:7890' || server == 'localhost:7890') {
    return true;
  }

  final endpoints = server
      .split(';')
      .where((entry) => entry.contains('='))
      .map((entry) => entry.substring(entry.indexOf('=') + 1))
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  return endpoints.isNotEmpty &&
      endpoints.every(
        (entry) => entry == '127.0.0.1:7890' || entry == 'localhost:7890',
      );
}

bool macOSProxyNeedsRestore({
  required bool usesLocalCore,
  required bool snapshotAvailable,
}) => usesLocalCore || snapshotAvailable;

bool macOSProxyRestoreSucceeded({
  required bool restored,
  required bool usesLocalCore,
  required Iterable<String> conflicts,
}) => restored && !usesLocalCore && conflicts.isEmpty;

enum MobileHealthDisposition { healthy, degraded, failed }

MobileHealthDisposition classifyMobileHealth({
  required bool runtimeReady,
  required bool publicReachable,
}) {
  if (!runtimeReady) return MobileHealthDisposition.failed;
  return publicReachable
      ? MobileHealthDisposition.healthy
      : MobileHealthDisposition.degraded;
}

bool iosTunnelSnapshotHasConnectedSystemState(
  ios_vless.IosTunnelSnapshot snapshot,
) => snapshot.state.toUpperCase() == 'CONNECTED';
