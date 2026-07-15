// Copyright (c) 2024-2026 13FOX Studio / tfox.dev.
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_vless/flutter_vless_ios.dart' show IosVlessStatus;
import 'package:flutter_vless/url/hysteria2.dart';
import 'package:flutter_vless/url/shadowsocks.dart';
import 'package:flutter_vless/url/socks.dart';
import 'package:flutter_vless/url/subscription.dart';
import 'package:flutter_vless/url/trojan.dart';
import 'package:flutter_vless/url/url.dart';
import 'package:flutter_vless/url/vless.dart';
import 'package:flutter_vless/url/vmess.dart';
import 'package:flutter_vless/url/xray_config.dart';
import 'package:flutter_vless/url/xray_config_model.dart';
import 'package:flutter_vless/url/xray_config_validator.dart';
import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart'
    hide VlessStatus;
import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart'
    as platform_status show VlessStatus;

export 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart'
    hide VlessStatus;
export 'url/url.dart';

/// Runtime status including the persistent native Packet Tunnel session ID.
class VlessStatus extends platform_status.VlessStatus {
  final String? sessionId;

  VlessStatus({
    super.duration,
    super.uploadSpeed,
    super.downloadSpeed,
    super.upload,
    super.download,
    super.state,
    required this.sessionId,
  });

  factory VlessStatus.fromPlatform(platform_status.VlessStatus status) {
    return VlessStatus(
      duration: status.duration,
      uploadSpeed: status.uploadSpeed,
      downloadSpeed: status.downloadSpeed,
      upload: status.upload,
      download: status.download,
      state: status.state,
      sessionId: status is IosVlessStatus ? status.sessionId : null,
    );
  }
}

class IosTunnelHealth {
  final String? sessionId;
  final bool healthy;
  final bool xrayRunning;
  final bool hevRunning;
  final bool socksInboundReady;
  final int? providerHttpStatusCode;
  final int? httpStatusCode;
  final String httpStatusLine;
  final String? failureReason;
  final DateTime? checkedAt;

  const IosTunnelHealth({
    required this.sessionId,
    required this.healthy,
    required this.xrayRunning,
    required this.hevRunning,
    required this.socksInboundReady,
    required this.providerHttpStatusCode,
    required this.httpStatusCode,
    required this.httpStatusLine,
    required this.failureReason,
    required this.checkedAt,
  });

  factory IosTunnelHealth.fromMap(Map<Object?, Object?> map) {
    final checkedAtMilliseconds = _nativeInt(map['checkedAtMilliseconds']);
    return IosTunnelHealth(
      sessionId: _nonEmptyNativeString(map['sessionId']),
      healthy: map['healthy'] == true,
      xrayRunning: map['xrayRunning'] == true,
      hevRunning: map['hevRunning'] == true,
      socksInboundReady: map['socksInboundReady'] == true,
      providerHttpStatusCode: map['providerHttpStatusCode'] == null
          ? null
          : _nativeInt(map['providerHttpStatusCode']),
      httpStatusCode: map['httpStatusCode'] == null
          ? null
          : _nativeInt(map['httpStatusCode']),
      httpStatusLine: map['httpStatusLine']?.toString() ?? '',
      failureReason: _nonEmptyNativeString(map['failureReason']),
      checkedAt: checkedAtMilliseconds <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(checkedAtMilliseconds),
    );
  }

  bool get hasExactHttp204 =>
      healthy && httpStatusCode == 204 && providerHttpStatusCode == 204;

  bool get runtimeReady => xrayRunning && hevRunning && socksInboundReady;
}

class IosTunnelSnapshot {
  final String state;
  final bool enabled;
  final int vpnStatus;
  final String? sessionId;
  final bool running;
  final int uploadBytes;
  final int downloadBytes;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final IosTunnelHealth? health;

  const IosTunnelSnapshot({
    required this.state,
    required this.enabled,
    required this.vpnStatus,
    required this.sessionId,
    required this.running,
    required this.uploadBytes,
    required this.downloadBytes,
    required this.startedAt,
    required this.updatedAt,
    required this.health,
  });

  factory IosTunnelSnapshot.fromMap(Map<Object?, Object?> map) {
    final session = map['session'] is Map
        ? Map<Object?, Object?>.from(map['session'] as Map)
        : const <Object?, Object?>{};
    final healthMap = map['health'] is Map
        ? Map<Object?, Object?>.from(map['health'] as Map)
        : null;
    final startedAt = _nativeInt(session['startedAtMilliseconds']);
    final updatedAt = _nativeInt(session['updatedAtMilliseconds']);
    return IosTunnelSnapshot(
      state: map['state']?.toString() ?? 'UNKNOWN',
      enabled: map['enabled'] == true,
      vpnStatus: _nativeInt(map['vpnStatus']),
      sessionId: _nonEmptyNativeString(session['sessionId']),
      running: session['running'] == true,
      uploadBytes: _nativeInt(session['uploadBytes']),
      downloadBytes: _nativeInt(session['downloadBytes']),
      startedAt: startedAt <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAt),
      updatedAt: updatedAt <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updatedAt),
      health: healthMap == null ? null : IosTunnelHealth.fromMap(healthMap),
    );
  }
}

int _nativeInt(Object? value) {
  if (value is int) return value < 0 ? 0 : value;
  if (value is num) return value.toInt().clamp(0, 0x7fffffffffffffff);
  return int.tryParse(value?.toString() ?? '')?.clamp(0, 0x7fffffffffffffff) ??
      0;
}

String? _nonEmptyNativeString(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// App-facing controller for Xray/V2Ray proxy and VPN tunnel sessions.
///
/// Use this class to parse VLESS, VMESS, Trojan, Shadowsocks, SOCKS,
/// subscription, Clash, sing-box, or raw Xray input into an Xray JSON config,
/// initialize the native platform backend, start or stop the local runtime, and
/// observe traffic/status updates through [onStatusChanged].
///
/// The class intentionally keeps the generated Xray JSON visible. That makes
/// simple proxy/VPN flows easy while still allowing advanced routing and
/// transport configuration when an app needs to edit the config before calling
/// [startVless].
class FlutterVless {
  /// Creates a controller and registers the callback used for status updates.
  ///
  /// Call [initializeVless] before starting a connection so the platform
  /// implementation can attach its method channel and status event stream.
  FlutterVless({required this.onStatusChanged});

  static const XrayConfigValidator _configValidator = XrayConfigValidator();
  static const MethodChannel _nativeChannel = MethodChannel('flutter_vless');

  /// Called whenever the active platform backend emits a new runtime status.
  ///
  /// Status values include elapsed duration, upload/download totals,
  /// upload/download speed, the raw native state string, and the normalized
  /// [VlessStatus.connectionState] enum.
  final void Function(VlessStatus status) onStatusChanged;

  /// Requests permission required by the current platform before tunnel mode.
  ///
  /// Android uses this for VPN/notification permission flows. iOS and macOS use
  /// their Network Extension profile/signing flow. Proxy-only mode usually does
  /// not need this call because it does not install a VPN route.
  ///
  /// Returns `true` when the platform reports that startup may continue.
  Future<bool> requestPermission() {
    return VlessPlatform.instance.requestPermission();
  }

  /// Initializes the native backend and subscribes to status events.
  ///
  /// [notificationIconResourceType] and [notificationIconResourceName] are used
  /// by Android foreground-service notifications.
  ///
  /// [providerBundleIdentifier] is the base app bundle identifier on Apple
  /// platforms, for example `com.example.myapp`. The iOS/macOS implementations
  /// append the packet tunnel suffix internally when they need the extension
  /// identifier.
  ///
  /// [groupIdentifier] is the Apple App Group shared by the app and Packet
  /// Tunnel extension, for example `group.com.example.myapp`.
  ///
  /// Call this once during app startup, before [startVless],
  /// [getConnectedServerDelay], or [getCoreVersion].
  Future<void> initializeVless({
    String notificationIconResourceType = "mipmap",
    String notificationIconResourceName = "ic_launcher",
    String providerBundleIdentifier = "",
    String groupIdentifier = "",
  }) async {
    await VlessPlatform.instance.initializeVless(
      onStatusChanged: (status) {
        onStatusChanged(VlessStatus.fromPlatform(status));
      },
      notificationIconResourceType: notificationIconResourceType,
      notificationIconResourceName: notificationIconResourceName,
      providerBundleIdentifier: providerBundleIdentifier,
      groupIdentifier: groupIdentifier,
    );
  }

  /// Starts an Xray-backed proxy or VPN/tunnel session.
  ///
  /// [remark] is a human-readable profile name used by native notifications,
  /// logs, and platform UI where available.
  ///
  /// [config] must be a JSON-encoded Xray configuration object. The string is
  /// validated before the native layer sees it; an [ArgumentError] is thrown
  /// when the JSON is malformed, is not an object, has invalid `inbounds`, or
  /// has no valid `outbounds`.
  ///
  /// [blockedApps] is Android-specific and contains package names that should
  /// be excluded from the VPN route.
  ///
  /// [bypassSubnets] contains CIDR routes that should be excluded from the
  /// tunnel on platforms that support route exclusions. Use it for local LAN,
  /// DNS, server-host, or app-specific bypass behavior.
  ///
  /// Set [proxyOnly] to `true` when the app should start local Xray proxy
  /// behavior without installing a system VPN or Packet Tunnel route.
  ///
  /// [notificationDisconnectButtonName] controls the Android foreground
  /// notification disconnect action label.
  Future<void> startVless({
    required String remark,
    required String config,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
    String notificationDisconnectButtonName = "DISCONNECT",
  }) async {
    final normalizedConfig = _normalizeConfigString(config);

    await VlessPlatform.instance.startVless(
      remark: remark,
      config: normalizedConfig,
      blockedApps: blockedApps,
      proxyOnly: proxyOnly,
      bypassSubnets: bypassSubnets,
      notificationDisconnectButtonName: notificationDisconnectButtonName,
    );
  }

  /// Stops the active proxy or VPN/tunnel session.
  ///
  /// Platform implementations also use this call to clean up foreground
  /// services, system proxy settings, local Xray processes, and tunnel state.
  Future<void> stopVless() async {
    await VlessPlatform.instance.stopVless();
  }

  /// Measures delay for an Xray config without relying on an active session.
  ///
  /// [config] is validated with the same JSON validator used by [startVless].
  /// [url] should point to a lightweight HTTP endpoint that returns quickly,
  /// such as `https://google.com/generate_204`.
  ///
  /// Returns delay in milliseconds, or the platform-specific failure value when
  /// the native backend cannot complete the probe.
  Future<int> getServerDelay(
      {required String config,
      String url = 'https://google.com/generate_204'}) async {
    final normalizedConfig = _normalizeConfigString(config);
    return await VlessPlatform.instance
        .getServerDelay(config: normalizedConfig, url: url);
  }

  /// Measures delay through the currently connected runtime.
  ///
  /// Use this after [startVless] when you want a health signal for the active
  /// profile rather than a separate temporary delay probe.
  Future<int> getConnectedServerDelay(
      {String url = 'https://google.com/generate_204'}) async {
    return await VlessPlatform.instance.getConnectedServerDelay(url);
  }

  /// Returns the embedded or discovered Xray core version string.
  ///
  /// The exact value is reported by the active platform implementation and can
  /// differ by package version, operating system, or externally supplied Windows
  /// `xray.exe`.
  Future<String> getCoreVersion() async {
    return await VlessPlatform.instance.getCoreVersion();
  }

  /// Runs a fresh end-to-end health check inside the Packet Tunnel extension.
  /// A healthy result requires Xray, HEV, the local SOCKS inbound, and an exact
  /// HTTP 204 response through the selected proxy node.
  Future<IosTunnelHealth> getTunnelHealth() async {
    final value = await _nativeChannel.invokeMapMethod<Object?, Object?>(
      'getTunnelHealth',
    );
    if (value == null) {
      throw StateError('The iOS Packet Tunnel returned no health result.');
    }
    return IosTunnelHealth.fromMap(value);
  }

  /// Returns NEVPN state plus the App Group's persistent session and counters.
  /// The session ID stays stable across Flutter process restarts and changes
  /// only when NetworkExtension starts a new Packet Tunnel session.
  Future<IosTunnelSnapshot> getTunnelSnapshot() async {
    final value = await _nativeChannel.invokeMapMethod<Object?, Object?>(
      'getTunnelSnapshot',
    );
    if (value == null) {
      throw StateError('The iOS Packet Tunnel returned no runtime snapshot.');
    }
    return IosTunnelSnapshot.fromMap(value);
  }

  /// Parse a share link, raw Xray JSON config, or subscription payload.
  ///
  /// Supports vmess://, vless://, trojan://, ss://, socks://, hysteria2://,
  /// hy2://, raw Xray JSON, base64 share-link subscriptions, Clash YAML, and
  /// sing-box JSON. Prefer this over [parseFromURL] for clipboard/subscription
  /// imports: raw JSON can carry VLESS Encryption keys that are not recoverable
  /// from a bare `vless://` link. If a subscription contains multiple supported
  /// profiles, this returns the first one; use [parseMany] to keep the full
  /// list.
  static FlutterVlessURL parse(String input) {
    final trimmed = input.trim();
    if (_isSingleShareLink(trimmed)) {
      return parseFromURL(trimmed);
    }
    return parseMany(trimmed).first;
  }

  /// Parse every supported profile from a subscription payload.
  ///
  /// Unsupported protocols are skipped intentionally. This plugin embeds Xray,
  /// so protocols that do not yet have a verified Xray import mapping should
  /// remain explicit product-scope gaps instead of silently producing broken
  /// Xray JSON. WireGuard, Hysteria2, and HTTP proxy profiles are supported in
  /// subscription import paths, but their runtime behavior still needs
  /// platform artifact validation before release.
  static List<FlutterVlessURL> parseMany(String input) {
    return VlessSubscriptionParser.parseMany(
      input: input,
      parseUrl: parseFromURL,
      parseJson: (json) => XrayJsonConfig(url: json),
    );
  }

  /// Parses a single share link into a typed [FlutterVlessURL] object.
  ///
  /// Supports `vmess://`, `vless://`, `trojan://`, `ss://`, `socks://`,
  /// `hysteria2://`, and `hy2://`.
  /// For raw Xray JSON, Clash YAML, sing-box JSON, or subscription payloads,
  /// use [parse] or [parseMany].
  static FlutterVlessURL parseFromURL(String url) {
    switch (url.split("://")[0].toLowerCase()) {
      case 'vmess':
        return VmessURL(url: url);
      case 'vless':
        return VlessURL(url: url);
      case 'trojan':
        return TrojanURL(url: url);
      case 'ss':
        return ShadowSocksURL(url: url);
      case 'socks':
        return SocksURL(url: url);
      case 'hysteria2':
      case 'hy2':
        return Hysteria2URL(url: url);
      default:
        throw ArgumentError('url is invalid');
    }
  }

  static bool _isSingleShareLink(String input) {
    if (input.contains('\n') || input.contains('\r')) {
      return false;
    }
    final separator = input.indexOf('://');
    if (separator <= 0) {
      return false;
    }
    return const {'vmess', 'vless', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2'}
        .contains(input.substring(0, separator).toLowerCase());
  }

  static String _normalizeConfigString(String config) {
    final decoded = _configValidator.validateJsonString(config);
    return jsonEncode(sanitizeXrayJson(decoded));
  }
}
