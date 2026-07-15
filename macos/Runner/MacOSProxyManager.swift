import Foundation
import Security
import SystemConfiguration
import Darwin

enum MacOSProxyManagerError: LocalizedError {
  case authorization(OSStatus)
  case preferences(String)
  case invalidArguments(String)
  case snapshot(String)

  var errorDescription: String? {
    switch self {
    case .authorization(let status):
      return "macOS authorization failed (OSStatus \(status))"
    case .preferences(let message), .invalidArguments(let message), .snapshot(let message):
      return message
    }
  }
}

/// Owns macOS system-proxy changes as a reversible transaction.
///
/// The complete Proxies protocol dictionary is persisted before the first
/// change. Restore only touches services that still carry Osca's endpoint, so
/// a proxy changed by the user (or another application) is never overwritten.
final class MacOSProxyManager {
  static let channelName = "osca/macos_proxy"

  private let applicationName = "Osca"
  private let queue = DispatchQueue(label: "ccwu.osca.macos-proxy")
  private let fileManager: FileManager
  private let snapshotURL: URL
  private var authorization: AuthorizationRef?

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
    let bundleName = Bundle.main.bundleIdentifier ?? "ccwu.osca"
    snapshotURL = base
      .appendingPathComponent(bundleName, isDirectory: true)
      .appendingPathComponent("macos-system-proxy.plist", isDirectory: false)
  }

  deinit {
    if let authorization {
      AuthorizationFree(authorization, [])
    }
  }

  func perform(
    _ operation: @escaping () throws -> Any,
    completion: @escaping (Result<Any, Error>) -> Void
  ) {
    queue.async {
      let value: Result<Any, Error>
      do {
        value = .success(try operation())
      } catch {
        value = .failure(error)
      }
      DispatchQueue.main.async { completion(value) }
    }
  }

  func readState() throws -> [String: Any] {
    guard let preferences = SCPreferencesCreate(
      nil,
      applicationName as CFString,
      nil
    ) else {
      throw MacOSProxyManagerError.preferences(
        "Unable to open macOS network preferences"
      )
    }
    SCPreferencesSynchronize(preferences)
    return buildState(preferences: preferences)
  }

  func apply(host: String = "127.0.0.1", port: Int = 7890) throws -> [String: Any] {
    guard isLoopback(host), port > 0, port <= 65_535 else {
      throw MacOSProxyManagerError.invalidArguments(
        "The system proxy endpoint must be a loopback address and a valid port"
      )
    }

    try withAuthorizedPreferences { preferences in
      let services = networkServices(preferences: preferences)
      guard !services.isEmpty else {
        throw MacOSProxyManagerError.preferences(
          "No configurable macOS network services were found"
        )
      }

      var snapshot = try loadSnapshot() ?? makeSnapshot(
        services: services,
        host: host,
        port: port
      )
      snapshot = try prepareSnapshotForApply(
        into: snapshot,
        services: services,
        host: host,
        port: port
      )
      try persistSnapshot(snapshot)

      var changed = 0
      for service in services where SCNetworkServiceGetEnabled(service) {
        guard let proxyProtocol = ensureProxyProtocol(service: service) else {
          throw MacOSProxyManagerError.preferences(
            "Unable to access proxy settings for \(serviceName(service))"
          )
        }
        var configuration = proxyConfiguration(proxyProtocol)
        setManagedProxy(
          configuration: &configuration,
          host: host,
          port: port
        )
        guard SCNetworkProtocolSetConfiguration(
          proxyProtocol,
          configuration as CFDictionary
        ), SCNetworkProtocolSetEnabled(proxyProtocol, true) else {
          throw MacOSProxyManagerError.preferences(
            "Unable to configure proxy settings for \(serviceName(service))"
          )
        }
        changed += 1
      }
      guard changed > 0 else {
        throw MacOSProxyManagerError.preferences(
          "No enabled macOS network services were found"
        )
      }
      try commitAndApply(preferences)
    }

    var state = try readState()
    state["applied"] = true
    state["conflicts"] = [String]()
    return state
  }

  func restore(force: Bool = false) throws -> [String: Any] {
    guard let snapshot = try loadSnapshot() else {
      var state = try readState()
      state["restored"] = true
      state["conflicts"] = [String]()
      return state
    }

    let managedHost = snapshot["managedHost"] as? String ?? "127.0.0.1"
    let managedPort = integer(snapshot["managedPort"]) ?? 7890
    let records = snapshot["services"] as? [[String: Any]] ?? []
    var conflicts = [String]()
    var unresolvedRecords = [[String: Any]]()

    try withAuthorizedPreferences { preferences in
      let currentServices = Dictionary(
        uniqueKeysWithValues: networkServices(preferences: preferences).compactMap {
          service -> (String, SCNetworkService)? in
          guard let identifier = serviceIdentifier(service) else { return nil }
          return (identifier, service)
        }
      )

      for record in records {
        guard boolean(record["changedByOsca"]) else { continue }
        guard let identifier = record["id"] as? String,
              let service = currentServices[identifier] else {
          // A deleted network service needs no restoration.
          continue
        }
        let currentProtocol = SCNetworkServiceCopyProtocol(
          service,
          kSCNetworkProtocolTypeProxies
        )
        let currentConfiguration = currentProtocol.map(proxyConfiguration) ?? [:]
        let protocolExisted = boolean(record["protocolExisted"])
        let original = record["configuration"] as? [String: Any] ?? [:]
        let originalProtocolEnabled = boolean(record["protocolEnabled"])
        let name = record["name"] as? String ?? identifier
        let alreadyRestored = protocolExisted
          ? currentProtocol != nil
            && proxyConfigurationsEqual(currentConfiguration, original)
            && currentProtocol.map { SCNetworkProtocolGetEnabled($0) }
              == originalProtocolEnabled
          : currentProtocol == nil
        if alreadyRestored { continue }

        if force {
          if protocolExisted {
            guard let proxyProtocol = currentProtocol ?? ensureProxyProtocol(service: service),
                  SCNetworkProtocolSetConfiguration(
                    proxyProtocol,
                    original as CFDictionary
                  ),
                  SCNetworkProtocolSetEnabled(
                    proxyProtocol,
                    originalProtocolEnabled
                  ) else {
              throw MacOSProxyManagerError.preferences(
                "Unable to force restore proxy settings for \(serviceName(service))"
              )
            }
          } else if currentProtocol != nil {
            guard SCNetworkServiceRemoveProtocolType(
              service,
              kSCNetworkProtocolTypeProxies
            ) else {
              throw MacOSProxyManagerError.preferences(
                "Unable to remove proxy settings for \(serviceName(service))"
              )
            }
          }
          continue
        }

        guard let proxyProtocol = currentProtocol else {
          conflicts.append("\(name): protocolRemoved")
          unresolvedRecords.append(record)
          continue
        }

        let configurationMerge = MacOSProxyPolicy.mergeConfigurationForRestore(
          original: original,
          current: currentConfiguration,
          host: managedHost,
          port: managedPort
        )
        var serviceConflicts = configurationMerge.conflicts

        if !protocolExisted {
          if configurationMerge.configuration.isEmpty && serviceConflicts.isEmpty {
            guard SCNetworkServiceRemoveProtocolType(
              service,
              kSCNetworkProtocolTypeProxies
            ) else {
              throw MacOSProxyManagerError.preferences(
                "Unable to remove proxy settings for \(serviceName(service))"
              )
            }
          } else {
            guard SCNetworkProtocolSetConfiguration(
              proxyProtocol,
              configurationMerge.configuration as CFDictionary
            ) else {
              throw MacOSProxyManagerError.preferences(
                "Unable to restore proxy settings for \(serviceName(service))"
              )
            }
          }
        } else {
          let enabledMerge = MacOSProxyPolicy.mergeProtocolEnabledForRestore(
            original: originalProtocolEnabled,
            current: SCNetworkProtocolGetEnabled(proxyProtocol)
          )
          if enabledMerge.conflict {
            serviceConflicts.append("protocolEnabled")
          }
          guard SCNetworkProtocolSetConfiguration(
            proxyProtocol,
            configurationMerge.configuration as CFDictionary
          ), SCNetworkProtocolSetEnabled(
            proxyProtocol,
            enabledMerge.enabled
          ) else {
            throw MacOSProxyManagerError.preferences(
              "Unable to restore proxy settings for \(serviceName(service))"
            )
          }
        }

        if !serviceConflicts.isEmpty {
          conflicts.append("\(name): \(serviceConflicts.joined(separator: ", "))")
          unresolvedRecords.append(record)
        }
      }
      try commitAndApply(preferences)
    }

    if unresolvedRecords.isEmpty {
      try removeSnapshot()
    } else {
      var remaining = snapshot
      remaining["services"] = unresolvedRecords
      try persistSnapshot(remaining)
    }

    var state = try readState()
    state["restored"] = conflicts.isEmpty
    state["conflicts"] = conflicts
    return state
  }

  func validateCore(path expectedPath: String, expectedPID: Int?) throws -> [String: Any] {
    guard !expectedPath.isEmpty else {
      throw MacOSProxyManagerError.invalidArguments(
        "The expected core executable path is required"
      )
    }
    let mixedPIDs = try listenerPIDs(port: 7890)
    let controllerPIDs = try listenerPIDs(port: 9090)
    let common = mixedPIDs.intersection(controllerPIDs)
    let uniqueListeners = mixedPIDs.count == 1 && controllerPIDs.count == 1
      && common.count == 1
    let pid = common.first
    let actualPath = pid.flatMap(processPath)
    let expectedCanonical = canonicalPath(expectedPath)
    let actualCanonical = actualPath.map(canonicalPath)
    let pidMatches = expectedPID == nil || pid == expectedPID
    let pathMatches = actualCanonical == expectedCanonical
    let valid = uniqueListeners && pidMatches && pathMatches

    var reason = ""
    if !uniqueListeners {
      reason = "Ports 7890 and 9090 are not owned by one unique process"
    } else if !pidMatches {
      reason = "The listener PID does not match the launched core"
    } else if !pathMatches {
      reason = "The listener executable path does not match the managed core"
    }

    return [
      "valid": valid,
      "pid": pid ?? 0,
      "path": actualPath ?? "",
      "expectedPath": expectedCanonical,
      "mixedPortPids": mixedPIDs.sorted(),
      "controllerPortPids": controllerPIDs.sorted(),
      "reason": reason,
    ]
  }

  private func buildState(preferences: SCPreferences) -> [String: Any] {
    let active = activeNetwork()
    let services = networkServices(preferences: preferences).map { service -> [String: Any] in
      let identifier = serviceIdentifier(service) ?? ""
      let proxyProtocol = SCNetworkServiceCopyProtocol(
        service,
        kSCNetworkProtocolTypeProxies
      )
      let configuration = proxyProtocol.map(proxyConfiguration) ?? [:]
      let protocolEnabled = proxyProtocol.map {
        SCNetworkProtocolGetEnabled($0)
      } ?? false
      let serviceEnabled = SCNetworkServiceGetEnabled(service)
      let usesLocalCore = serviceEnabled
        && MacOSProxyPolicy.isStrictlyCaptured(
          configuration: configuration,
          protocolEnabled: protocolEnabled
        )
      return [
        "id": identifier,
        "name": serviceName(service),
        "enabled": serviceEnabled,
        "active": active.serviceIDs.contains(identifier),
        "protocolEnabled": protocolEnabled,
        "http": proxyEntry(
          configuration,
          enableKey: "HTTPEnable",
          hostKey: "HTTPProxy",
          portKey: "HTTPPort"
        ),
        "https": proxyEntry(
          configuration,
          enableKey: "HTTPSEnable",
          hostKey: "HTTPSProxy",
          portKey: "HTTPSPort"
        ),
        "socks": proxyEntry(
          configuration,
          enableKey: "SOCKSEnable",
          hostKey: "SOCKSProxy",
          portKey: "SOCKSPort"
        ),
        "pac": [
          "enabled": boolean(configuration["ProxyAutoConfigEnable"]),
          "url": configuration["ProxyAutoConfigURLString"] as? String ?? "",
        ],
        "autoDiscovery": boolean(configuration["ProxyAutoDiscoveryEnable"]),
        "bypass": configuration["ExceptionsList"] as? [String] ?? [],
        "excludeSimpleHostnames": boolean(configuration["ExcludeSimpleHostnames"]),
        "usesLocalCore": usesLocalCore,
      ]
    }

    let enabled = MacOSProxyPolicy.allApplicableServicesCaptured(services)
    return [
      "enabled": enabled,
      "usesLocalCore": enabled,
      "server": enabled ? "127.0.0.1:7890" : "",
      "activeServiceId": active.primaryServiceID,
      "activeInterface": active.primaryInterface,
      "activeServiceIds": Array(active.serviceIDs).sorted(),
      "activeInterfaces": Array(active.interfaces).sorted(),
      "services": services,
      "snapshotAvailable": fileManager.fileExists(atPath: snapshotURL.path),
    ]
  }

  private func makeSnapshot(
    services: [SCNetworkService],
    host: String,
    port: Int
  ) -> [String: Any] {
    [
      "version": 1,
      "createdAt": ISO8601DateFormatter().string(from: Date()),
      "managedHost": host,
      "managedPort": port,
      "services": services.compactMap(snapshotRecord),
    ]
  }

  private func prepareSnapshotForApply(
    into snapshot: [String: Any],
    services: [SCNetworkService],
    host: String,
    port: Int
  ) throws -> [String: Any] {
    var merged = snapshot
    var records = snapshot["services"] as? [[String: Any]] ?? []
    let identifiers = Set(records.compactMap { $0["id"] as? String })
    records.append(contentsOf: services.compactMap { service in
      guard let identifier = serviceIdentifier(service),
            !identifiers.contains(identifier) else { return nil }
      return snapshotRecord(service)
    })
    let previousHost = snapshot["managedHost"] as? String ?? "127.0.0.1"
    let previousPort = integer(snapshot["managedPort"]) ?? 7890
    let serviceByIdentifier = Dictionary(
      uniqueKeysWithValues: services.compactMap { service -> (String, SCNetworkService)? in
        guard let identifier = serviceIdentifier(service) else { return nil }
        return (identifier, service)
      }
    )
    for index in records.indices {
      guard let identifier = records[index]["id"] as? String,
            let service = serviceByIdentifier[identifier],
            SCNetworkServiceGetEnabled(service) else { continue }

      let currentProtocol = SCNetworkServiceCopyProtocol(
        service,
        kSCNetworkProtocolTypeProxies
      )
      let currentConfiguration = currentProtocol.map(proxyConfiguration) ?? [:]
      if boolean(records[index]["changedByOsca"]) {
        let original = records[index]["configuration"] as? [String: Any] ?? [:]
        let protocolOriginallyExisted = boolean(records[index]["protocolExisted"])
        let equalsOriginal = protocolOriginallyExisted
          ? currentProtocol != nil
            && proxyConfigurationsEqual(currentConfiguration, original)
            && currentProtocol.map { SCNetworkProtocolGetEnabled($0) }
              == boolean(records[index]["protocolEnabled"])
          : currentProtocol == nil
        guard equalsOriginal || isManagedProxy(
          currentConfiguration,
          protocolEnabled: currentProtocol.map {
            SCNetworkProtocolGetEnabled($0)
          } ?? false,
          host: previousHost,
          port: previousPort
        ) else {
          throw MacOSProxyManagerError.preferences(
            "Proxy settings for \(serviceName(service)) are controlled by another application"
          )
        }
      } else if let refreshed = snapshotRecord(service) {
        // It was not previously modified by Osca. Capture any user changes
        // made while the service was disabled before taking ownership now.
        records[index] = refreshed
      }
      records[index]["changedByOsca"] = true
    }
    merged["managedHost"] = host
    merged["managedPort"] = port
    merged["services"] = records
    return merged
  }

  private func snapshotRecord(_ service: SCNetworkService) -> [String: Any]? {
    guard let identifier = serviceIdentifier(service) else { return nil }
    let proxyProtocol = SCNetworkServiceCopyProtocol(
      service,
      kSCNetworkProtocolTypeProxies
    )
    return [
      "id": identifier,
      "name": serviceName(service),
      "serviceEnabled": SCNetworkServiceGetEnabled(service),
      "changedByOsca": false,
      "protocolExisted": proxyProtocol != nil,
      "protocolEnabled": proxyProtocol.map {
        SCNetworkProtocolGetEnabled($0)
      } ?? false,
      "configuration": proxyProtocol.map(proxyConfiguration) ?? [:],
    ]
  }

  private func setManagedProxy(
    configuration: inout [String: Any],
    host: String,
    port: Int
  ) {
    configuration = MacOSProxyPolicy.managedConfiguration(
      from: configuration,
      host: host,
      port: port
    )
  }

  private func isManagedProxy(
    _ configuration: [String: Any],
    protocolEnabled: Bool,
    host: String,
    port: Int
  ) -> Bool {
    MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: protocolEnabled,
      host: host,
      port: port
    )
  }

  private func proxyEntry(
    _ configuration: [String: Any],
    enableKey: String,
    hostKey: String,
    portKey: String
  ) -> [String: Any] {
    [
      "enabled": boolean(configuration[enableKey]),
      "host": configuration[hostKey] as? String ?? "",
      "port": integer(configuration[portKey]) ?? 0,
    ]
  }

  private func proxyConfigurationsEqual(
    _ left: [String: Any],
    _ right: [String: Any]
  ) -> Bool {
    NSDictionary(dictionary: left).isEqual(to: right)
  }

  private func withAuthorizedPreferences<T>(
    _ body: (SCPreferences) throws -> T
  ) throws -> T {
    if authorization == nil {
      let flags: AuthorizationFlags = [
        .interactionAllowed,
        .extendRights,
        .preAuthorize,
      ]
      var createdAuthorization: AuthorizationRef?
      let status = AuthorizationCreate(
        nil,
        nil,
        flags,
        &createdAuthorization
      )
      guard status == errAuthorizationSuccess,
            let createdAuthorization else {
        throw MacOSProxyManagerError.authorization(status)
      }
      authorization = createdAuthorization
    }
    guard let authorization else {
      throw MacOSProxyManagerError.authorization(errAuthorizationInternal)
    }

    guard let preferences = SCPreferencesCreateWithAuthorization(
      nil,
      applicationName as CFString,
      nil,
      authorization
    ) else {
      throw MacOSProxyManagerError.preferences(
        "Unable to open authorized macOS network preferences"
      )
    }
    guard SCPreferencesLock(preferences, true) else {
      throw MacOSProxyManagerError.preferences(
        "Unable to lock macOS network preferences"
      )
    }
    defer { SCPreferencesUnlock(preferences) }
    SCPreferencesSynchronize(preferences)
    return try body(preferences)
  }

  private func commitAndApply(_ preferences: SCPreferences) throws {
    guard SCPreferencesCommitChanges(preferences) else {
      throw MacOSProxyManagerError.preferences(
        "Unable to save macOS network preferences"
      )
    }
    guard SCPreferencesApplyChanges(preferences) else {
      throw MacOSProxyManagerError.preferences(
        "Unable to apply macOS network preferences"
      )
    }
  }

  private func ensureProxyProtocol(
    service: SCNetworkService
  ) -> SCNetworkProtocol? {
    if let existing = SCNetworkServiceCopyProtocol(
      service,
      kSCNetworkProtocolTypeProxies
    ) {
      return existing
    }
    guard SCNetworkServiceAddProtocolType(
      service,
      kSCNetworkProtocolTypeProxies
    ) else { return nil }
    return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
  }

  private func networkServices(preferences: SCPreferences) -> [SCNetworkService] {
    let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []
    return services.sorted { serviceName($0) < serviceName($1) }
  }

  private func serviceIdentifier(_ service: SCNetworkService) -> String? {
    SCNetworkServiceGetServiceID(service) as String?
  }

  private func serviceName(_ service: SCNetworkService) -> String {
    SCNetworkServiceGetName(service) as String? ?? serviceIdentifier(service) ?? "Unknown"
  }

  private func proxyConfiguration(
    _ proxyProtocol: SCNetworkProtocol
  ) -> [String: Any] {
    SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any] ?? [:]
  }

  private func activeNetwork() -> (
    serviceIDs: Set<String>,
    interfaces: Set<String>,
    primaryServiceID: String,
    primaryInterface: String
  ) {
    guard let store = SCDynamicStoreCreate(
      nil,
      applicationName as CFString,
      nil,
      nil
    ) else { return ([], [], "", "") }
    var serviceIDs = Set<String>()
    var interfaces = Set<String>()
    var primaryServiceID = ""
    var primaryInterface = ""
    for family in ["IPv4", "IPv6"] {
      let key = "State:/Network/Global/\(family)" as CFString
      guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any] else {
        continue
      }
      if let identifier = value["PrimaryService"] as? String {
        serviceIDs.insert(identifier)
        if primaryServiceID.isEmpty || family == "IPv4" {
          primaryServiceID = identifier
        }
      }
      if let interface = value["PrimaryInterface"] as? String {
        interfaces.insert(interface)
        if primaryInterface.isEmpty || family == "IPv4" {
          primaryInterface = interface
        }
      }
    }
    return (serviceIDs, interfaces, primaryServiceID, primaryInterface)
  }

  private func loadSnapshot() throws -> [String: Any]? {
    guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
    do {
      let data = try Data(contentsOf: snapshotURL)
      let value = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
      guard let snapshot = value as? [String: Any],
            integer(snapshot["version"]) == 1 else {
        throw MacOSProxyManagerError.snapshot(
          "The saved macOS proxy snapshot has an unsupported format"
        )
      }
      return snapshot
    } catch let error as MacOSProxyManagerError {
      throw error
    } catch {
      throw MacOSProxyManagerError.snapshot(
        "Unable to read the saved macOS proxy snapshot: \(error.localizedDescription)"
      )
    }
  }

  private func persistSnapshot(_ snapshot: [String: Any]) throws {
    do {
      let directory = snapshotURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let data = try PropertyListSerialization.data(
        fromPropertyList: snapshot,
        format: .binary,
        options: 0
      )
      try data.write(to: snapshotURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: snapshotURL.path
      )
    } catch {
      throw MacOSProxyManagerError.snapshot(
        "Unable to save the macOS proxy snapshot: \(error.localizedDescription)"
      )
    }
  }

  private func removeSnapshot() throws {
    guard fileManager.fileExists(atPath: snapshotURL.path) else { return }
    do {
      try fileManager.removeItem(at: snapshotURL)
    } catch {
      throw MacOSProxyManagerError.snapshot(
        "The proxy was restored, but its saved snapshot could not be removed: \(error.localizedDescription)"
      )
    }
  }

  private func listenerPIDs(port: Int) throws -> Set<Int> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = [
      "-nP",
      "-a",
      "-iTCP:\(port)",
      "-sTCP:LISTEN",
      "-Fp",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw MacOSProxyManagerError.preferences(
        "Unable to inspect TCP port \(port): \(error.localizedDescription)"
      )
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    return Set(text.split(whereSeparator: { $0.isNewline }).compactMap { line in
      guard line.first == "p" else { return nil }
      return Int(line.dropFirst())
    })
  }

  private func processPath(pid: Int) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBytes { bytes in
      proc_pidpath(Int32(pid), bytes.baseAddress, UInt32(bytes.count))
    }
    guard length > 0 else { return nil }
    return String(cString: buffer)
  }

  private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
  }

  private func normalizedHost(_ host: String) -> String {
    let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "localhost" || value == "::1" || value == "[::1]" {
      return "127.0.0.1"
    }
    return value
  }

  private func isLoopback(_ host: String) -> Bool {
    normalizedHost(host) == "127.0.0.1"
  }

  private func boolean(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      return ["1", "true", "yes", "on"].contains(text.lowercased())
    }
    return false
  }

  private func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Int { return number }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
