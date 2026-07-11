// lib/features/vpn/repositories/vpn_repository_impl.dart
import 'dart:async';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessSignal, ProcessStartMode;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vpn_app/features/vpn/mappers/vpn_mapper.dart';
import 'package:vpn_app/features/vpn/models/dto/vpn_config_dto.dart';
import 'package:vpn_app/features/vpn/models/vpn_config.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../../../core/api/api_service.dart';
import '../../../core/errors/error_mapper.dart';
import '../platform/vpn_channel.dart';
import '../platform/vpn_isolates.dart';
import '../platform/vpn_permissions.dart';
import '../models/subscription_node.dart';
import 'vpn_repository.dart';

class VpnRepositoryImpl implements VpnRepository {
  VpnRepositoryImpl(this._api, {required this.selectedNode});

  final ApiService _api;
  final SubscriptionNode? Function() selectedNode;
  final VpnChannel _vpn = VpnChannel();
  FlutterV2ray? _v2ray;
  bool _v2rayConnected = false;
  Process? _clashProcess;

  static const String _tunnelName = 'vpn_app_tunnel';
  static const String _bundleId = 'com.example.vpn_app';

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
    if (node.raw.startsWith('vless://') ||
        node.raw.startsWith('vmess://') ||
        node.raw.startsWith('trojan://') ||
        node.raw.startsWith('ss://')) {
      if (Platform.isWindows || Platform.isMacOS) {
        await _connectClash(node);
      } else {
        await _connectV2ray(node);
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
    if (_clashProcess != null) {
      await _setDesktopProxy(false);
      _clashProcess!.kill(ProcessSignal.sigterm);
      _clashProcess = null;
      return;
    }
    if (_v2ray != null) {
      await _v2ray!.stopV2Ray();
      _v2rayConnected = false;
      return;
    }
    await _vpn.stop();
  }

  @override
  Future<bool> isConnected() async {
    if (_clashProcess != null) return true;
    if (_v2rayConnected) return true;
    final s = await _vpn.stage();
    return s == VpnStage.connected;
  }

  Future<void> _connectV2ray(SubscriptionNode node) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台尚未安装 VLESS 原生核心');
    }
    final engine = _v2ray ??= FlutterV2ray(
      onStatusChanged: (status) {
        final state = status.state.toUpperCase();
        _v2rayConnected = state.contains('CONNECTED');
      },
    );
    await engine.initializeV2Ray();
    final allowed = await engine.requestPermission();
    if (!allowed) throw Exception('未获得 VPN 权限');
    final parser = FlutterV2ray.parseFromURL(node.raw);
    await engine.startV2Ray(
      remark: parser.remark,
      config: parser.getFullConfiguration(),
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );
    _v2rayConnected = true;
  }

  Future<void> _connectClash(SubscriptionNode node) async {
    await disconnect();
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}clash',
    );
    await directory.create(recursive: true);

    final response = await _api.get<String>(
      '/v1/link',
      options: Options(responseType: ResponseType.plain),
    );
    if ((response.statusCode ?? 0) < 200 || (response.statusCode ?? 0) >= 300) {
      throwFromResponse(response);
    }
    final yaml = 'mixed-port: 7890\n${response.data ?? ''}';
    await File(
      '${directory.path}${Platform.pathSeparator}config.yaml',
    ).writeAsString(yaml);

    final asset = await _desktopCoreAsset();
    final coreName = Platform.isWindows ? 'Clash-Coco.exe' : 'Clash-Coco';
    final core = File('${directory.path}${Platform.pathSeparator}$coreName');
    final bytes = await rootBundle.load(asset);
    await core.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    if (Platform.isMacOS) await Process.run('chmod', ['+x', core.path]);

    _clashProcess = await Process.start(core.path, [
      '-d',
      directory.path,
      '-ext-ctl',
      '127.0.0.1:9090',
    ], mode: ProcessStartMode.detachedWithStdio);
    await Future.delayed(const Duration(milliseconds: 800));
    await Dio().put(
      'http://127.0.0.1:9090/proxies/Proxy',
      data: {'name': node.name},
    );
    await _setDesktopProxy(true);
  }

  Future<String> _desktopCoreAsset() async {
    if (Platform.isWindows) return 'assets/cores/windows/Clash-Coco.exe';
    final result = await Process.run('uname', ['-m']);
    final arm = result.stdout.toString().trim().contains('arm64');
    return arm
        ? 'assets/cores/macos-arm64/Clash-Coco'
        : 'assets/cores/macos-x64/Clash-Coco';
  }

  Future<void> _setDesktopProxy(bool enabled) async {
    if (Platform.isWindows) {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      await Process.run('reg', [
        'add',
        key,
        '/v',
        'ProxyEnable',
        '/t',
        'REG_DWORD',
        '/d',
        enabled ? '1' : '0',
        '/f',
      ]);
      if (enabled) {
        await Process.run('reg', [
          'add',
          key,
          '/v',
          'ProxyServer',
          '/t',
          'REG_SZ',
          '/d',
          '127.0.0.1:7890',
          '/f',
        ]);
      }
      await Process.run('RunDll32.exe', [
        'InetCpl.cpl,ClearMyTracksByProcess',
        '8',
      ]);
      return;
    }
    if (Platform.isMacOS) {
      final result = await Process.run('networksetup', [
        '-listallnetworkservices',
      ]);
      final services = result.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .skip(1)
          .where((line) => line.trim().isNotEmpty && !line.startsWith('*'));
      for (final service in services) {
        if (enabled) {
          await Process.run('networksetup', [
            '-setwebproxy',
            service,
            '127.0.0.1',
            '7890',
          ]);
          await Process.run('networksetup', [
            '-setsecurewebproxy',
            service,
            '127.0.0.1',
            '7890',
          ]);
        } else {
          await Process.run('networksetup', [
            '-setwebproxystate',
            service,
            'off',
          ]);
          await Process.run('networksetup', [
            '-setsecurewebproxystate',
            service,
            'off',
          ]);
        }
      }
    }
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
