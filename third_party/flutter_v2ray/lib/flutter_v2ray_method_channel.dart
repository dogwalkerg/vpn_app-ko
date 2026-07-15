import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'model/v2ray_status.dart' show V2RayStatus;

import 'flutter_v2ray_platform_interface.dart';

/// An implementation of [FlutterV2rayPlatform] that uses method channels.
class MethodChannelFlutterV2ray extends FlutterV2rayPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_v2ray');
  final eventChannel = const EventChannel('flutter_v2ray/status');
  StreamSubscription<dynamic>? _statusSubscription;

  V2RayStatus _statusFromNative(dynamic event) {
    if (event is Map) {
      return V2RayStatus(
        duration: event['duration']?.toString() ?? '00:00:00',
        uploadSpeed: int.tryParse(event['uploadSpeed']?.toString() ?? '') ?? 0,
        downloadSpeed:
            int.tryParse(event['downloadSpeed']?.toString() ?? '') ?? 0,
        upload: int.tryParse(event['upload']?.toString() ?? '') ?? 0,
        download: int.tryParse(event['download']?.toString() ?? '') ?? 0,
        state: event['state']?.toString() ?? 'DISCONNECTED',
        error: event['error']?.toString() ?? '',
        sessionId: event['sessionId']?.toString() ?? '',
        generation: int.tryParse(event['generation']?.toString() ?? '') ?? 0,
      );
    }
    final values = event as List;
    return V2RayStatus(
      duration: values[0].toString(),
      uploadSpeed: int.tryParse(values[1].toString()) ?? 0,
      downloadSpeed: int.tryParse(values[2].toString()) ?? 0,
      upload: int.tryParse(values[3].toString()) ?? 0,
      download: int.tryParse(values[4].toString()) ?? 0,
      state: values[5].toString(),
      error: values.length > 6 ? values[6].toString() : '',
      sessionId: values.length > 7 ? values[7].toString() : '',
      generation:
          values.length > 8 ? int.tryParse(values[8].toString()) ?? 0 : 0,
    );
  }

  @override
  Future<void> initializeV2Ray({
    required void Function(V2RayStatus status) onStatusChanged,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
  }) async {
    await _statusSubscription?.cancel();
    _statusSubscription = eventChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        onStatusChanged.call(_statusFromNative(event));
      }
    });
    await methodChannel.invokeMethod(
      'initializeV2Ray',
      {
        "notificationIconResourceType": notificationIconResourceType,
        "notificationIconResourceName": notificationIconResourceName,
      },
    );
    onStatusChanged.call(await getV2RayStatus());
  }

  @override
  Future<void> startV2Ray({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
  }) async {
    await methodChannel.invokeMethod('startV2Ray', {
      "remark": remark,
      "config": config,
      "blocked_apps": blockedApps,
      "bypass_subnets": bypassSubnets,
      "proxy_only": proxyOnly,
      "notificationDisconnectButtonName": notificationDisconnectButtonName,
    });
  }

  @override
  Future<void> stopV2Ray() async {
    await methodChannel.invokeMethod('stopV2Ray');
  }

  @override
  Future<V2RayStatus> getV2RayStatus() async {
    final status = await methodChannel.invokeMethod<dynamic>('getV2RayStatus');
    return _statusFromNative(status);
  }

  @override
  Future<int> getServerDelay(
      {required String config, required String url}) async {
    return await methodChannel.invokeMethod('getServerDelay', {
      "config": config,
      "url": url,
    });
  }

  @override
  Future<int> getConnectedServerDelay(String url) async {
    return await methodChannel
        .invokeMethod('getConnectedServerDelay', {"url": url});
  }

  @override
  Future<bool> requestPermission() async {
    return (await methodChannel.invokeMethod('requestPermission')) ?? false;
  }

  @override
  Future<String> getCoreVersion() async {
    return await methodChannel.invokeMethod('getCoreVersion');
  }
}
