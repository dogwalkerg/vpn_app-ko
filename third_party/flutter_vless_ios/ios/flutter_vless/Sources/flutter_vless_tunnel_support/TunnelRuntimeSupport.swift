import Foundation

public enum TunnelRuntimePolicy {
    public static let dnsServers = ["1.1.1.1", "8.8.8.8"]
    public static let healthProbeHost = "www.gstatic.com"
    public static let healthProbePath = "/generate_204"
    public static let healthProbeExpectedStatus = 204
    public static let maximumHevLogBytes = 512 * 1024
    public static let retainedHevLogBytes = 96 * 1024
    public static let capturesIPv6DefaultRoute = true
    public static let routesDNSInsideTunnel = true

    /// Only the physical proxy endpoint may bypass the tunnel to prevent a
    /// routing loop. Public DNS resolver addresses must never appear here.
    public static func proxyEndpointExclusions(_ addresses: [String]) -> [String] {
        Array(Set(addresses.filter { !dnsServers.contains($0) })).sorted()
    }

    public static func safeIPv4BypassCIDRs(_ cidrs: [String]) -> [String] {
        cidrs.filter { cidr in
            !dnsServers.contains { ipv4Address($0, isContainedIn: cidr) }
        }
    }

    private static func ipv4Address(_ address: String, isContainedIn cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let network = ipv4Value(String(parts[0])),
              let candidate = ipv4Value(address),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix) else {
            return false
        }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        return (network & mask) == (candidate & mask)
    }

    private static func ipv4Value(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let number = UInt32(octet), number <= 255 else { return nil }
            result = (result << 8) | number
        }
        return result
    }

    public static var xrayLogLevel: String {
        #if DEBUG
        return "debug"
        #else
        return "warning"
        #endif
    }

    public static var hevLogLevel: String {
        #if DEBUG
        return "debug"
        #else
        return "warn"
        #endif
    }
}

public struct TunnelHTTPProbeResult: Codable, Equatable {
    public let success: Bool
    public let statusCode: Int?
    public let statusLine: String
    public let failureReason: String?

    public init(success: Bool, statusCode: Int?, statusLine: String, failureReason: String?) {
        self.success = success
        self.statusCode = statusCode
        self.statusLine = statusLine
        self.failureReason = failureReason
    }
}

public enum TunnelHTTPProbeEvaluator {
    public static func evaluate(
        response: Data,
        expectedStatus: Int = TunnelRuntimePolicy.healthProbeExpectedStatus
    ) -> TunnelHTTPProbeResult {
        let text = String(decoding: response, as: UTF8.self)
        let firstLine = text.components(separatedBy: "\r\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let statusCode = fields.count >= 2 ? Int(fields[1]) : nil
        guard fields.first?.hasPrefix("HTTP/") == true, let statusCode else {
            return TunnelHTTPProbeResult(
                success: false,
                statusCode: nil,
                statusLine: firstLine,
                failureReason: "Invalid HTTP health response"
            )
        }
        guard statusCode == expectedStatus else {
            return TunnelHTTPProbeResult(
                success: false,
                statusCode: statusCode,
                statusLine: firstLine,
                failureReason: "Expected HTTP \(expectedStatus), received \(statusCode)"
            )
        }
        return TunnelHTTPProbeResult(
            success: true,
            statusCode: statusCode,
            statusLine: firstLine,
            failureReason: nil
        )
    }
}

public struct TunnelHealthSnapshot: Codable, Equatable {
    public let sessionId: String
    public let healthy: Bool
    public let xrayRunning: Bool
    public let hevRunning: Bool
    public let socksInboundReady: Bool
    public let httpStatusCode: Int?
    public let httpStatusLine: String
    public let failureReason: String?
    public let checkedAtMilliseconds: Int64

    public var runtimeReady: Bool {
        xrayRunning && hevRunning && socksInboundReady
    }

    public init(
        sessionId: String,
        healthy: Bool,
        xrayRunning: Bool,
        hevRunning: Bool,
        socksInboundReady: Bool,
        httpStatusCode: Int?,
        httpStatusLine: String,
        failureReason: String?,
        checkedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.sessionId = sessionId
        self.healthy = healthy
        self.xrayRunning = xrayRunning
        self.hevRunning = hevRunning
        self.socksInboundReady = socksInboundReady
        self.httpStatusCode = httpStatusCode
        self.httpStatusLine = httpStatusLine
        self.failureReason = failureReason
        self.checkedAtMilliseconds = checkedAtMilliseconds
    }

    public func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

public struct TunnelSessionSnapshot: Codable, Equatable {
    public let sessionId: String
    public let startedAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64
    public let running: Bool
    public let uploadBytes: Int64
    public let downloadBytes: Int64

    public init(
        sessionId: String,
        startedAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        running: Bool,
        uploadBytes: Int64,
        downloadBytes: Int64
    ) {
        self.sessionId = sessionId
        self.startedAtMilliseconds = startedAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.running = running
        self.uploadBytes = max(0, uploadBytes)
        self.downloadBytes = max(0, downloadBytes)
    }

    public func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

public struct TunnelRuntimeSnapshot: Codable, Equatable {
    public let session: TunnelSessionSnapshot?
    public let health: TunnelHealthSnapshot?

    public init(session: TunnelSessionSnapshot?, health: TunnelHealthSnapshot?) {
        self.session = session
        self.health = health
    }

    public func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// Thread-safe state shared by Runner and the Packet Tunnel extension.
///
/// The extension owns the authoritative session totals. Keeping them in the
/// App Group prevents a newly launched Runner from treating an already active
/// tunnel as a brand-new zero-byte session.
public final class TunnelSharedStateStore: @unchecked Sendable {
    private static let sessionKey = "flutter_vless.tunnel.session.v1"
    private static let healthKey = "flutter_vless.tunnel.health.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init?(groupIdentifier: String) {
        guard !groupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let defaults = UserDefaults(suiteName: groupIdentifier) else {
            return nil
        }
        self.defaults = defaults
    }

    public func save(session: TunnelSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        withLock { defaults.set(data, forKey: Self.sessionKey) }
    }

    public func loadSession() -> TunnelSessionSnapshot? {
        withLock {
            guard let data = defaults.data(forKey: Self.sessionKey) else { return nil }
            return try? JSONDecoder().decode(TunnelSessionSnapshot.self, from: data)
        }
    }

    public func save(health: TunnelHealthSnapshot) {
        guard let data = try? JSONEncoder().encode(health) else { return }
        withLock { defaults.set(data, forKey: Self.healthKey) }
    }

    public func loadHealth() -> TunnelHealthSnapshot? {
        withLock {
            guard let data = defaults.data(forKey: Self.healthKey) else { return nil }
            return try? JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)
        }
    }

    public func snapshot() -> TunnelRuntimeSnapshot {
        TunnelRuntimeSnapshot(session: loadSession(), health: loadHealth())
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

public enum TunnelRotatingLog {
    @discardableResult
    public static func rotateIfNeeded(
        at url: URL,
        maximumBytes: Int = TunnelRuntimePolicy.maximumHevLogBytes,
        retainedBytes: Int = TunnelRuntimePolicy.retainedHevLogBytes
    ) -> Bool {
        guard maximumBytes > 0,
              retainedBytes >= 0,
              retainedBytes < maximumBytes,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maximumBytes,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        let tail = Data(data.suffix(retainedBytes))
        do {
            try tail.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func tail(at url: URL, maximumLines: Int = 40) -> String? {
        guard maximumLines > 0,
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty else {
            return nil
        }
        return content.split(separator: "\n").suffix(maximumLines).joined(separator: "\n")
    }
}
