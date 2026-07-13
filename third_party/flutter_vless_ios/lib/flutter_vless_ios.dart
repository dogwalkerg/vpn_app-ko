import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart';

/// iOS implementation of [VlessPlatform] using MethodChannel.
class FlutterVlessIOS extends VlessMethodChannelAdapter {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    VlessPlatform.instance = FlutterVlessIOS();
  }
}
