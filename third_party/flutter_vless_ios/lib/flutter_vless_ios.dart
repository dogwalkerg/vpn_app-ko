import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart'
    as platform;

/// Native iOS status with the Packet Tunnel's persistent session identifier.
///
/// The superclass keeps compatibility with the platform interface while this
/// extra value lets the app distinguish a resumed tunnel from a newly started
/// one after the Flutter process is relaunched.
class IosVlessStatus extends platform.VlessStatus {
  final String? sessionId;

  IosVlessStatus({
    required super.duration,
    required super.uploadSpeed,
    required super.downloadSpeed,
    required super.upload,
    required super.download,
    required super.state,
    required this.sessionId,
  });

  factory IosVlessStatus.fromEvent(Object? event) {
    final status = platform.VlessStatus.fromEvent(event);
    final sessionId = event is Map<Object?, Object?>
        ? event['sessionId']?.toString().trim()
        : null;
    return IosVlessStatus(
      duration: status.duration,
      uploadSpeed: status.uploadSpeed,
      downloadSpeed: status.downloadSpeed,
      upload: status.upload,
      download: status.download,
      state: status.state,
      sessionId: sessionId == null || sessionId.isEmpty ? null : sessionId,
    );
  }
}

/// iOS implementation of [platform.VlessPlatform] using MethodChannel.
class FlutterVlessIOS extends platform.VlessMethodChannelAdapter {
  static const MethodChannel _methodChannel = MethodChannel('flutter_vless');
  static const EventChannel _eventChannel =
      EventChannel('flutter_vless/status');
  StreamSubscription<dynamic>? _statusSubscription;

  /// Registers this class as the platform implementation.
  static void registerWith() {
    platform.VlessPlatform.instance = FlutterVlessIOS();
  }

  @override
  Future<void> initializeVless({
    required void Function(platform.VlessStatus status) onStatusChanged,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
    required String providerBundleIdentifier,
    required String groupIdentifier,
  }) async {
    await _statusSubscription?.cancel();
    _statusSubscription = _eventChannel.receiveBroadcastStream().listen(
      (Object? event) {
        try {
          onStatusChanged(IosVlessStatus.fromEvent(event));
        } on FormatException {
          debugPrint('Ignoring malformed iOS VLESS status payload: $event');
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('iOS VLESS status stream error: $error');
      },
    );

    await _methodChannel.invokeMethod<void>('initializeVless', {
      'notificationIconResourceType': notificationIconResourceType,
      'notificationIconResourceName': notificationIconResourceName,
      'providerBundleIdentifier': providerBundleIdentifier,
      'groupIdentifier': groupIdentifier,
    });
  }
}
