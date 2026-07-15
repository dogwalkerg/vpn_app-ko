import Foundation

struct MacOSProxyConfigurationMerge {
  let configuration: [String: Any]
  let conflicts: [String]
}

struct MacOSProxyEnabledMerge {
  let enabled: Bool
  let conflict: Bool
}

/// Pure policy checks shared by the Runner and its unit-test target.
enum MacOSProxyPolicy {
  static let managedConfigurationKeys = [
    "HTTPEnable",
    "HTTPProxy",
    "HTTPPort",
    "HTTPSEnable",
    "HTTPSProxy",
    "HTTPSPort",
    "SOCKSEnable",
    "SOCKSProxy",
    "SOCKSPort",
    "ProxyAutoConfigEnable",
    "ProxyAutoDiscoveryEnable",
    "ExceptionsList",
    "ExcludeSimpleHostnames",
  ]

  static func managedConfiguration(
    from original: [String: Any],
    host: String = "127.0.0.1",
    port: Int = 7890
  ) -> [String: Any] {
    var configuration = original
    for (enable, server, portKey) in [
      ("HTTPEnable", "HTTPProxy", "HTTPPort"),
      ("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
      ("SOCKSEnable", "SOCKSProxy", "SOCKSPort"),
    ] {
      configuration[enable] = 1
      configuration[server] = host
      configuration[portKey] = port
    }
    configuration["ProxyAutoConfigEnable"] = 0
    configuration["ProxyAutoDiscoveryEnable"] = 0
    configuration["ExceptionsList"] = [String]()
    configuration["ExcludeSimpleHostnames"] = 0
    return configuration
  }

  static func mergeConfigurationForRestore(
    original: [String: Any],
    current: [String: Any],
    host: String = "127.0.0.1",
    port: Int = 7890,
    force: Bool = false
  ) -> MacOSProxyConfigurationMerge {
    let managed = managedConfiguration(from: original, host: host, port: port)
    var merged = current
    var conflicts = [String]()

    for key in managedConfigurationKeys {
      let currentValue = current[key]
      let originalValue = original[key]
      let managedValue = managed[key]
      if force || propertyListValuesEqual(currentValue, managedValue) {
        if let originalValue {
          merged[key] = originalValue
        } else {
          merged.removeValue(forKey: key)
        }
      } else if !propertyListValuesEqual(currentValue, originalValue) {
        conflicts.append(key)
      }
    }
    return MacOSProxyConfigurationMerge(
      configuration: merged,
      conflicts: conflicts
    )
  }

  /// Osca always enables the Proxies protocol while connected. A disabled
  /// protocol is therefore a user-owned change only when it was enabled in
  /// the original snapshot as well.
  static func mergeProtocolEnabledForRestore(
    original: Bool,
    current: Bool,
    force: Bool = false
  ) -> MacOSProxyEnabledMerge {
    if force || current {
      return MacOSProxyEnabledMerge(enabled: original, conflict: false)
    }
    if current == original {
      return MacOSProxyEnabledMerge(enabled: current, conflict: false)
    }
    return MacOSProxyEnabledMerge(enabled: current, conflict: true)
  }

  static func isStrictlyCaptured(
    configuration: [String: Any],
    protocolEnabled: Bool,
    host: String = "127.0.0.1",
    port: Int = 7890
  ) -> Bool {
    guard protocolEnabled else { return false }
    let expectedHost = normalizedHost(host)
    let proxies = [
      ("HTTPEnable", "HTTPProxy", "HTTPPort"),
      ("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
      ("SOCKSEnable", "SOCKSProxy", "SOCKSPort"),
    ]
    guard proxies.allSatisfy({ enableKey, hostKey, portKey in
      guard boolean(configuration[enableKey]),
            let configuredHost = configuration[hostKey] as? String else {
        return false
      }
      return normalizedHost(configuredHost) == expectedHost
        && integer(configuration[portKey]) == port
    }) else { return false }

    guard !boolean(configuration["ProxyAutoConfigEnable"]),
          !boolean(configuration["ProxyAutoDiscoveryEnable"]),
          !boolean(configuration["ExcludeSimpleHostnames"]),
          bypassListIsEmpty(configuration["ExceptionsList"]) else {
      return false
    }
    return true
  }

  static func allApplicableServicesCaptured(
    _ services: [[String: Any]]
  ) -> Bool {
    let active = services.filter { boolean($0["active"]) }
    let applicable = active.isEmpty
      ? services.filter { boolean($0["enabled"]) }
      : active
    return !applicable.isEmpty
      && applicable.allSatisfy {
        boolean($0["enabled"]) && boolean($0["usesLocalCore"])
      }
  }

  private static func bypassListIsEmpty(_ value: Any?) -> Bool {
    guard let value else { return true }
    if let entries = value as? [Any] { return entries.isEmpty }
    if let entries = value as? NSArray { return entries.count == 0 }
    return false
  }

  private static func normalizedHost(_ host: String) -> String {
    let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "localhost" || value == "::1" || value == "[::1]" {
      return "127.0.0.1"
    }
    return value
  }

  private static func boolean(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      return ["1", "true", "yes", "on"].contains(text.lowercased())
    }
    return false
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Int { return number }
    if let text = value as? String { return Int(text) }
    return nil
  }

  private static func propertyListValuesEqual(_ left: Any?, _ right: Any?) -> Bool {
    switch (left, right) {
    case (nil, nil):
      return true
    case (nil, _), (_, nil):
      return false
    case let (left?, right?):
      return NSDictionary(dictionary: ["value": left]).isEqual(
        to: ["value": right]
      )
    }
  }
}
