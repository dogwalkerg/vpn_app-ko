//
//  PacketTunnelProvider.swift
//  XrayTunnel
//
//  Created by Vladimir Khudiakov on 17.08.2025. https://tfox.dev.
//

import NetworkExtension
import XRay
import Tun2SocksKit
import flutter_vless_tunnel_support
import os
import Darwin

private let tunnelLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "flutter_vless.XrayTunnel",
    category: "PacketTunnel"
)
private let tunnelMTU = 1500
#if DEBUG
private let providerTrafficLogInterval: TimeInterval = 5
#else
private let providerTrafficLogInterval: TimeInterval = 60
#endif

private enum HevLifecycleState: Equatable {
    case idle
    case scheduled
    case running
    case stopping
}

/// iOS runs this extension in a separate process from the Flutter app, and the
/// Runner console does not reliably show extension stdout. Keeping a small
/// in-memory ring buffer lets the app ask the provider for the exact startup
/// and health-check evidence that matters on a real device.
private final class TunnelDebugStore {
    static let shared = TunnelDebugStore()
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 120

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        lines.append("\(timestamp) \(message)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

private func rememberTunnelLog(_ message: String) {
    TunnelDebugStore.shared.append(message)
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let logger = CustomXRayLogger()
    private let lifecycleLock = NSLock()
    private let healthLock = NSLock()
    private let hevLifecycleLock = NSLock()
    private let healthQueue = DispatchQueue(label: "flutter_vless.packet_tunnel.health", qos: .utility)
    private var tunnelStopping = false
    private var xrayRunning = false
    private var hevRunning = false
    private var hevLifecycleState: HevLifecycleState = .idle
    private var hevGeneration: UInt64 = 0
    private var healthCheckInFlight = false
    private var healthGeneration: UInt64 = 0
    private var healthCheckCompletions: [(
        generation: UInt64,
        completion: (TunnelHealthSnapshot) -> Void
    )] = []
    private var consecutiveHealthFailures = 0
    private var healthTimer: DispatchSourceTimer?
    private var lastTrafficLogDate: Date = .distantPast
    private var hevLogURL: URL?
    private var sharedStateStore: TunnelSharedStateStore?
    private var tunnelSessionId = ""
    private var tunnelStartedAtMilliseconds: Int64 = 0
    private var inboundPort: Int?

    override func startTunnel(options: [String : NSObject]? = nil) async throws {
        setTunnelStopping(false)
        beginHealthGeneration()
        rememberTunnelLog("Starting Xray packet tunnel")
        tunnelLog.info("Starting Xray packet tunnel options=\(String(describing: options), privacy: .public)")
        guard
            let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = protocolConfiguration.providerConfiguration
        else {
            throw tunnelError("Missing tunnel provider configuration")
        }
        tunnelLog.info("Provider configuration keys: \(providerConfiguration.keys.sorted().joined(separator: ","), privacy: .public)")
        guard let xrayConfig: Data = providerConfiguration["xrayConfig"] as? Data else {
            throw tunnelError("Missing Xray config")
        }
        guard let groupIdentifier = providerConfiguration["groupIdentifier"] as? String,
              let sharedStateStore = TunnelSharedStateStore(groupIdentifier: groupIdentifier) else {
            throw tunnelError("Missing or unavailable App Group for tunnel state")
        }
        self.sharedStateStore = sharedStateStore
        tunnelSessionId = UUID().uuidString.lowercased()
        tunnelStartedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        sharedStateStore.save(session: TunnelSessionSnapshot(
            sessionId: tunnelSessionId,
            startedAtMilliseconds: tunnelStartedAtMilliseconds,
            running: true,
            uploadBytes: 0,
            downloadBytes: 0
        ))
        tunnelLog.info("Received Xray config bytes=\(xrayConfig.count, privacy: .public)")
        let preparedXrayConfig = prepareXrayConfigForTunnel(xrayConfig) ?? xrayConfig
        let bypassSubnets = providerConfiguration["bypassSubnets"] as? [String] ?? []
        tunnelLog.info("Bypass subnet count=\(bypassSubnets.count, privacy: .public)")
        if (providerConfiguration["proxyOnly"] as? Bool) == true {
            tunnelLog.warning("proxyOnly is not supported by the iOS packet tunnel; starting VPN mode")
        }
        guard let parsedConfig = parseConfig(jsonData: preparedXrayConfig) else {
            throw tunnelError("Unable to find a SOCKS/HTTP inbound port in Xray config")
        }
        inboundPort = parsedConfig.inboundPort
        if let serverAddress = parsedConfig.serverAddress,
           !isIPv4Literal(serverAddress),
           !isIPv6Literal(serverAddress) {
            throw tunnelError("Proxy server domain was not resolved before tunnel routing: \(serverAddress)")
        }
        rememberTunnelLog("Using local Xray inbound port \(parsedConfig.inboundPort), server=\(parsedConfig.serverAddress ?? "nil")")
        tunnelLog.info("Using local Xray inbound port \(parsedConfig.inboundPort, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = NSNumber(value: tunnelMTU)
        settings.ipv4Settings = {
            let settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
            settings.includedRoutes = [NEIPv4Route.default()]
            settings.excludedRoutes = buildIPv4ExcludedRoutes(
                serverAddress: parsedConfig.serverAddress,
                bypassSubnets: bypassSubnets
            )
            tunnelLog.info("IPv4 settings address=198.18.0.1/16 includedRoutes=default excludedRoutes=\(settings.excludedRoutes?.count ?? 0, privacy: .public)")
            return settings
        }()
        settings.ipv6Settings = {
            let settings = NEIPv6Settings(
                addresses: ["fd00:198:18::1"],
                networkPrefixLengths: [64]
            )
            // Capturing ::/0 prevents Safari or another app from falling back
            // to the physical IPv6 interface when the selected node is IPv4.
            // HEV and Xray can carry IPv6 destinations; unsupported traffic
            // fails inside the tunnel instead of exposing the real IPv6 path.
            settings.includedRoutes = [NEIPv6Route.default()]
            settings.excludedRoutes = buildIPv6ExcludedRoutes(serverAddress: parsedConfig.serverAddress)
            return settings
        }()
        rememberTunnelLog("IPv6 default route captured by packet tunnel")
        tunnelLog.info("IPv6 default route captured by packet tunnel")
        settings.dnsSettings = {
            // These resolver addresses are deliberately not excluded below.
            // Their UDP/TCP packets therefore follow the same HEV -> SOCKS ->
            // Xray path as browser traffic and cannot leave on the physical
            // Wi-Fi/cellular interface.
            let settings = NEDNSSettings(servers: TunnelRuntimePolicy.dnsServers)
            settings.matchDomains = [""]
            return settings
        }()
        rememberTunnelLog("DNS captured by tunnel servers=\(TunnelRuntimePolicy.dnsServers.joined(separator: ","))")
        tunnelLog.info("Applying tunnel network settings")
        do {
            try await self.setTunnelNetworkSettings(settings)
            tunnelLog.info("Tunnel network settings applied")
            try self.startXRay(xrayConfig: preparedXrayConfig)
            try self.startSocks5Tunnel(serverPort: parsedConfig.inboundPort)
            let initialHealth = await waitForInitialHealth()
            guard initialHealth.healthy else {
                throw tunnelError(initialHealth.failureReason ?? "Packet tunnel health check failed")
            }
            startContinuousHealthMonitoring()
        } catch {
            failTunnel(error)
            throw error
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        setTunnelStopping(true)
        invalidateHealthChecks()
        tunnelLog.info("Stopping Xray packet tunnel, reason: \(reason.rawValue, privacy: .public)")
        logTrafficStats(context: "stop")
        stopContinuousHealthMonitoring()
        persistSession(running: false)
        persistHealth(healthy: false, failureReason: "Tunnel stopped (reason \(reason.rawValue))")
        stopRuntime()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            if (message == "xray_traffic"){
                logTrafficStats(context: "poll")
                persistSession(running: true)
                completionHandler?(runtimeSnapshotData())
            } else if (message == "xray_health") {
                requestHealthCheck { snapshot in
                    completionHandler?(snapshot.jsonData())
                }
            } else if (message == "xray_snapshot") {
                persistSession(running: true)
                completionHandler?(runtimeSnapshotData())
            } else if (message == "xray_debug") {
                // This bridge is intentionally part of the runtime API used by
                // smoke tests and manual Xcode runs. It is the fastest way to
                // compare TCP/Reality and XHTTP behavior without attaching LLDB
                // to the extension process separately.
                var snapshot = TunnelDebugStore.shared.snapshot()
                if let hevTail = readHevLogTail(), !hevTail.isEmpty {
                    snapshot += "\n--- HEV log tail ---\n\(hevTail)"
                }
                completionHandler?(snapshot.data(using: .utf8))
            }else if (message.hasPrefix("xray_delay")){
                var error: NSError?
                var delay: Int64 = -1
                let url = String(message[message.index(message.startIndex, offsetBy: 10)...])
                tunnelLog.info("Measuring connected delay url=\(url, privacy: .public)")
                XRayMeasureDelay(url, &delay, &error)
                if let error {
                    tunnelLog.error("Connected delay error: \(error.localizedDescription, privacy: .public)")
                } else {
                    tunnelLog.info("Connected delay result=\(delay, privacy: .public)")
                }
                completionHandler?("\(delay)".data(using: .utf8))
            }
            else{
                tunnelLog.info("Echoing unknown provider message: \(message, privacy: .public)")
                completionHandler?(messageData)
            }

        }else{
            tunnelLog.warning("Received non-UTF8 provider message bytes=\(messageData.count, privacy: .public)")
            completionHandler?(messageData)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        tunnelLog.info("Packet tunnel sleep")
        completionHandler()
    }

    override func wake() {
        tunnelLog.info("Packet tunnel wake")
    }

    private func startSocks5Tunnel(serverPort port: Int) throws {
        // HEV is the tun2socks bridge: it reads IP packets from NetworkExtension
        // and forwards them into the local SOCKS inbound opened by Xray.
        // Xray alone can start successfully while user traffic still cannot
        // leave the device; HEV logs close that gap during real-device tests.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("hev-socks5-tunnel.log")
        hevLogURL = logURL
        try? FileManager.default.removeItem(at: logURL)
        let config = """
        tunnel:
          mtu: \(tunnelMTU)
        socks5:
          port: \(port)
          address: 127.0.0.1
          udp: 'udp'
        misc:
          task-stack-size: 20480
          connect-timeout: 5000
          read-write-timeout: 60000
          log-file: \(logURL.path)
          log-level: \(TunnelRuntimePolicy.hevLogLevel)
          limit-nofile: 65535
        """
        guard let generation = scheduleHevStart() else {
            throw tunnelError("HEV tun2socks startup was cancelled")
        }
        rememberTunnelLog("Starting HEV socks5 tunnel on 127.0.0.1:\(port), log=\(logURL.path)")
        tunnelLog.info("Starting HEV socks5 tunnel on 127.0.0.1:\(port, privacy: .public), mtu \(tunnelMTU, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.beginHevRun(generation: generation) else { return }
            tunnelLog.info("HEV socks5 tunnel thread entered")
            let exitCode = Socks5Tunnel.run(withConfig: .string(content: config))
            let wasCurrent = self.finishHevRun(generation: generation)
            rememberTunnelLog("HEV socks5 tunnel exited with code \(exitCode)")
            tunnelLog.error("HEV socks5 tunnel exited with code \(exitCode, privacy: .public)")
            NSLog("HEV_SOCKS5_TUNNEL_MAIN: \(exitCode)")
            DispatchQueue.main.async { [weak self] in
                guard let self, wasCurrent, !self.isTunnelStopping() else { return }
                self.failTunnel(self.tunnelError("Tun2Socks exited unexpectedly with code \(exitCode)"))
            }
        }
    }

    private func startXRay(xrayConfig: Data) throws {
        // TODO: Set memory limit
        XRaySetMemoryLimit()

        // Create an error pointer
        var error: NSError?

        // Start XRay with the config data
        tunnelLog.info("Starting XRay version=\(XRayGetVersion(), privacy: .public) configBytes=\(xrayConfig.count, privacy: .public)")
        let started = XRayStart(xrayConfig, logger, &error)

        if started {
            setXrayRunning(true)
            rememberTunnelLog("XRay started successfully")
            tunnelLog.info("XRay started successfully")
        } else if let error = error {
            rememberTunnelLog("Failed to start XRay: \(error.localizedDescription)")
            tunnelLog.error("Failed to start XRay: \(error.localizedDescription, privacy: .public)")
            throw error
        } else {
            rememberTunnelLog("Failed to start XRay with unknown error")
            throw tunnelError("Failed to start XRay with unknown error")
        }
    }

    private func stopXRay() {
        guard isXrayRunning() else { return }
        XRayStop()
        setXrayRunning(false)
        tunnelLog.info("XRay stopped \(XRayGetVersion(), privacy: .public)")
    }

    private struct ParsedConfig {
        let inboundPort: Int
        let serverAddress: String?
    }

    private func parseConfig(jsonData: Data) -> ParsedConfig? {
        guard let parsed = TunnelXrayConfigPreparer.parseConfig(jsonData: jsonData) else {
            tunnelLog.error("Failed to parse tunnel Xray config")
            return nil
        }
        if let serverAddress = parsed.serverAddress {
            tunnelLog.info("Parsed outbound server address: \(serverAddress, privacy: .public)")
        } else {
            tunnelLog.warning("Could not parse outbound server address; VPN routing loop exclusion will be skipped")
        }
        return ParsedConfig(inboundPort: parsed.inboundPort, serverAddress: parsed.serverAddress)
    }

    /// Normalizes imported Xray JSON for iOS packet-tunnel constraints.
    ///
    /// The same URL parser is used for standalone Xray configs and for this
    /// extension, but iOS has tighter rules: file logs may be denied inside the
    /// extension sandbox, DNS must line up with `NEDNSSettings`, and the remote
    /// proxy server must not be reached through the tunnel that depends on it.
    private func prepareXrayConfigForTunnel(_ jsonData: Data) -> Data? {
        guard let prepared = TunnelXrayConfigPreparer.prepare(
            jsonData: jsonData,
            resolveIPv4: { resolveIPv4Addresses(for: $0).first },
            logLevel: TunnelRuntimePolicy.xrayLogLevel
        ) else {
            tunnelLog.warning("Could not prepare Xray config for iOS tunnel")
            return nil
        }
        for message in prepared.logMessages {
            rememberTunnelLog(message)
            tunnelLog.info("\(message, privacy: .public)")
        }
        return prepared.data
    }

    private func buildIPv4ExcludedRoutes(serverAddress: String?, bypassSubnets: [String]) -> [NEIPv4Route] {
        let safeBypassSubnets = TunnelRuntimePolicy.safeIPv4BypassCIDRs(bypassSubnets)
        if safeBypassSubnets.count != bypassSubnets.count {
            rememberTunnelLog("Ignored bypass subnet that would route tunnel DNS physically")
            tunnelLog.warning("Ignored bypass subnet that contains a tunnel DNS server")
        }
        var routes = safeBypassSubnets.compactMap { ipv4Route(fromCIDR: $0) }
        if let serverAddress {
            let serverAddresses = TunnelRuntimePolicy.proxyEndpointExclusions(
                resolveIPv4Addresses(for: serverAddress)
            )
            let serverRoutes = serverAddresses.map {
                NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
            }
            routes.append(contentsOf: serverRoutes)
            if serverRoutes.isEmpty {
                rememberTunnelLog("No IPv4 address resolved for outbound server \(serverAddress)")
                tunnelLog.warning("No IPv4 address resolved for outbound server \(serverAddress, privacy: .public)")
            } else {
                rememberTunnelLog("Excluded IPv4 server route(s): \(serverAddresses.joined(separator: ","))")
                tunnelLog.info("Excluded \(serverRoutes.count, privacy: .public) IPv4 server route(s) from VPN: \(serverAddresses.joined(separator: ","), privacy: .public)")
            }
        }
        return routes
    }

    private func socksInboundHealthCheck(port: Int) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            return "socket failed errno=\(errno)"
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return "inet_pton failed"
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return "connect 127.0.0.1:\(port) failed errno=\(errno)"
        }

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        let sent = greeting.withUnsafeBytes {
            send(fd, $0.baseAddress, greeting.count, 0)
        }
        guard sent == greeting.count else {
            return "send greeting failed sent=\(sent) errno=\(errno)"
        }

        var response = [UInt8](repeating: 0, count: 2)
        let responseCount = response.count
        let received = response.withUnsafeMutableBytes {
            recv(fd, $0.baseAddress, responseCount, 0)
        }
        guard received == 2 else {
            return "recv greeting failed received=\(received) errno=\(errno)"
        }

        return "ok response=\(response.map { String(format: "%02x", $0) }.joined(separator: " "))"
    }

    private func socksConnectHealthCheck(port: Int) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            return "socket failed errno=\(errno)"
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return "inet_pton failed"
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return "connect 127.0.0.1:\(port) failed errno=\(errno)"
        }

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard sendAll(fd: fd, bytes: greeting) else {
            return "send greeting failed errno=\(errno)"
        }
        guard let greetingResponse = recvExact(fd: fd, count: 2) else {
            return "recv greeting failed errno=\(errno)"
        }
        guard greetingResponse == [0x05, 0x00] else {
            return "unexpected greeting=\(hex(greetingResponse))"
        }

        let request: [UInt8] = [
            0x05, 0x01, 0x00, 0x01,
            0x01, 0x01, 0x01, 0x01,
            0x00, 0x50
        ]
        guard sendAll(fd: fd, bytes: request) else {
            return "send connect failed errno=\(errno)"
        }
        guard let header = recvExact(fd: fd, count: 4) else {
            return "recv connect header failed errno=\(errno)"
        }
        guard header.count == 4 else {
            return "short connect header=\(hex(header))"
        }
        let atyp = header[3]
        let remaining: Int
        switch atyp {
        case 0x01:
            remaining = 6
        case 0x03:
            guard let lengthBytes = recvExact(fd: fd, count: 1), let length = lengthBytes.first else {
                return "recv domain length failed errno=\(errno)"
            }
            remaining = Int(length) + 2
        case 0x04:
            remaining = 18
        default:
            return "unexpected connect atyp=\(String(format: "%02x", atyp)) header=\(hex(header))"
        }
        let tail = recvExact(fd: fd, count: remaining) ?? []
        let status = header[1] == 0x00 ? "ok" : "failed"
        return "\(status) response=\(hex(header + tail))"
    }

    /// Performs an HTTP request through the same local SOCKS inbound used by HEV.
    ///
    /// This is the decisive regression signal for the current investigation:
    /// TCP/Reality returned `HTTP/1.1 204 No Content` on device, while failing
    /// XHTTP links reached earlier stages but did not return usable page bytes.
    private func socksHTTPHealthCheck(port: Int) -> TunnelHTTPProbeResult {
        let host = TunnelRuntimePolicy.healthProbeHost
        let path = TunnelRuntimePolicy.healthProbePath
        let hostBytes = Array(host.utf8)
        guard hostBytes.count <= 255 else {
            return failedHTTPProbe("Health probe host is too long")
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            return failedHTTPProbe("Health probe socket failed errno=\(errno)")
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return failedHTTPProbe("Health probe inet_pton failed")
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return failedHTTPProbe("Health probe could not connect to local SOCKS port errno=\(errno)")
        }

        guard sendAll(fd: fd, bytes: [0x05, 0x01, 0x00]),
              let greetingResponse = recvExact(fd: fd, count: 2),
              greetingResponse == [0x05, 0x00] else {
            return failedHTTPProbe("Health probe SOCKS greeting failed errno=\(errno)")
        }

        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        request.append(contentsOf: hostBytes)
        request.append(0x00)
        request.append(0x50)
        guard sendAll(fd: fd, bytes: request) else {
            return failedHTTPProbe("Health probe SOCKS CONNECT send failed errno=\(errno)")
        }
        guard let header = recvExact(fd: fd, count: 4) else {
            return failedHTTPProbe("Health probe SOCKS CONNECT response failed errno=\(errno)")
        }
        guard header.count == 4, header[1] == 0x00 else {
            return failedHTTPProbe("Health probe SOCKS CONNECT rejected response=\(hex(header))")
        }
        let atyp = header[3]
        let remaining: Int
        switch atyp {
        case 0x01:
            remaining = 6
        case 0x03:
            guard let lengthBytes = recvExact(fd: fd, count: 1), let length = lengthBytes.first else {
                return failedHTTPProbe("Health probe SOCKS domain response failed errno=\(errno)")
            }
            remaining = Int(length) + 2
        case 0x04:
            remaining = 18
        default:
            return failedHTTPProbe("Health probe SOCKS returned address type \(String(format: "%02x", atyp))")
        }
        _ = recvExact(fd: fd, count: remaining)

        let httpRequest = """
        GET \(path) HTTP/1.1\r
        Host: \(host)\r
        User-Agent: flutter-vless-healthcheck\r
        Connection: close\r
        \r

        """
        guard sendAll(fd: fd, bytes: Array(httpRequest.utf8)) else {
            return failedHTTPProbe("Health probe HTTP send failed errno=\(errno)")
        }
        guard let response = recvHTTPStatusLine(fd: fd, maxCount: 512), !response.isEmpty else {
            return failedHTTPProbe("Health probe HTTP response failed errno=\(errno)")
        }
        return TunnelHTTPProbeEvaluator.evaluate(response: Data(response))
    }

    private func failedHTTPProbe(_ reason: String) -> TunnelHTTPProbeResult {
        TunnelHTTPProbeResult(
            success: false,
            statusCode: nil,
            statusLine: "",
            failureReason: reason
        )
    }

    private func sendAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sentTotal = 0
        while sentTotal < bytes.count {
            let sent = bytes.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: sentTotal), bytes.count - sentTotal, 0)
            }
            guard sent > 0 else {
                return false
            }
            sentTotal += sent
        }
        return true
    }

    private func recvExact(fd: Int32, count: Int) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let bufferCount = buffer.count
            let received = buffer.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress, bufferCount, 0)
            }
            guard received > 0 else {
                return nil
            }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    private func recvSome(fd: Int32, maxCount: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maxCount)
        let received = buffer.withUnsafeMutableBytes {
            recv(fd, $0.baseAddress, maxCount, 0)
        }
        guard received > 0 else {
            return nil
        }
        return Array(buffer.prefix(received))
    }

    private func recvHTTPStatusLine(fd: Int32, maxCount: Int) -> [UInt8]? {
        var result: [UInt8] = []
        while result.count < maxCount {
            let remaining = min(128, maxCount - result.count)
            guard let bytes = recvSome(fd: fd, maxCount: remaining), !bytes.isEmpty else {
                return result.isEmpty ? nil : result
            }
            result.append(contentsOf: bytes)
            if result.indices.dropFirst().contains(where: { index in
                result[index - 1] == 0x0d && result[index] == 0x0a
            }) {
                return result
            }
        }
        return result
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func requestHealthCheck(_ completion: @escaping (TunnelHealthSnapshot) -> Void) {
        if isTunnelStopping() {
            completion(cancelledHealthSnapshot())
            return
        }
        healthLock.lock()
        let generation = healthGeneration
        healthCheckCompletions.append((generation, completion))
        if healthCheckInFlight {
            healthLock.unlock()
            return
        }
        healthCheckInFlight = true
        healthLock.unlock()

        runHealthCheck(generation: generation)
    }

    private func runHealthCheck(generation: UInt64) {
        healthQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.performHealthCheck()

            self.healthLock.lock()
            let completions = self.healthCheckCompletions
                .filter { $0.generation == generation }
                .map { $0.completion }
            self.healthCheckCompletions.removeAll { $0.generation == generation }
            let isCurrent = self.healthGeneration == generation
            let shouldApply = isCurrent && !self.isTunnelStopping()
            if shouldApply {
                self.sharedStateStore?.save(health: snapshot)
            }
            let nextGeneration = self.healthCheckCompletions.first?.generation
            self.healthCheckInFlight = nextGeneration != nil
            self.healthLock.unlock()

            if shouldApply {
                completions.forEach { $0(snapshot) }
                self.handleHealthResult(snapshot)
            } else {
                let cancelled = self.cancelledHealthSnapshot()
                completions.forEach { $0(cancelled) }
            }
            if let nextGeneration {
                self.runHealthCheck(generation: nextGeneration)
            }
        }
    }

    private func performHealthCheck() -> TunnelHealthSnapshot {
        let flags = runtimeFlags()
        guard let port = inboundPort else {
            return healthSnapshot(
                healthy: false,
                socksInboundReady: false,
                httpResult: failedHTTPProbe("Tunnel inbound port is unavailable"),
                xrayRunning: flags.xray,
                hevRunning: flags.hev
            )
        }

        TunnelRotatingLog.rotateIfNeeded(at: hevLogURL ?? FileManager.default.temporaryDirectory)
        let inboundResult = socksInboundHealthCheck(port: port)
        let inboundReady = inboundResult.hasPrefix("ok ")
        let connectResult = inboundReady ? "covered by HTTP probe" : "skipped"
        let httpResult = inboundReady
            ? socksHTTPHealthCheck(port: port)
            : failedHTTPProbe("Local SOCKS inbound is not ready: \(inboundResult)")
        let currentFlags = runtimeFlags()
        let healthy = currentFlags.xray && currentFlags.hev && inboundReady && httpResult.success
        rememberTunnelLog("Health xray=\(currentFlags.xray) hev=\(currentFlags.hev) socks=\(inboundResult) connect=\(connectResult) http=\(httpResult.statusLine) healthy=\(healthy)")
        if healthy {
            #if DEBUG
            tunnelLog.info("Tunnel health passed with exact HTTP \(httpResult.statusCode ?? -1, privacy: .public)")
            #endif
        } else {
            tunnelLog.error("Tunnel health failed: \(httpResult.failureReason ?? inboundResult, privacy: .public)")
        }
        return healthSnapshot(
            healthy: healthy,
            socksInboundReady: inboundReady,
            httpResult: httpResult,
            xrayRunning: currentFlags.xray,
            hevRunning: currentFlags.hev
        )
    }

    private func healthSnapshot(
        healthy: Bool,
        socksInboundReady: Bool,
        httpResult: TunnelHTTPProbeResult,
        xrayRunning: Bool,
        hevRunning: Bool
    ) -> TunnelHealthSnapshot {
        var failureReason = httpResult.failureReason
        if !xrayRunning {
            failureReason = "Xray is not running"
        } else if !hevRunning {
            failureReason = "HEV tun2socks is not running"
        } else if !socksInboundReady {
            failureReason = failureReason ?? "Local SOCKS inbound is not ready"
        }
        return TunnelHealthSnapshot(
            sessionId: tunnelSessionId,
            healthy: healthy,
            xrayRunning: xrayRunning,
            hevRunning: hevRunning,
            socksInboundReady: socksInboundReady,
            httpStatusCode: httpResult.statusCode,
            httpStatusLine: httpResult.statusLine,
            failureReason: healthy ? nil : failureReason
        )
    }

    private func waitForInitialHealth() async -> TunnelHealthSnapshot {
        var latest = healthSnapshot(
            healthy: false,
            socksInboundReady: false,
            httpResult: failedHTTPProbe("Initial health check has not run"),
            xrayRunning: isXrayRunning(),
            hevRunning: isHevRunning()
        )
        for attempt in 1...2 {
            try? await Task.sleep(nanoseconds: attempt == 1 ? 500_000_000 : 750_000_000)
            latest = await withCheckedContinuation { continuation in
                requestHealthCheck { continuation.resume(returning: $0) }
            }
            if latest.healthy { return latest }
            rememberTunnelLog("Initial tunnel health attempt \(attempt) failed: \(latest.failureReason ?? "unknown")")
        }
        return latest
    }

    private func startContinuousHealthMonitoring() {
        stopContinuousHealthMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.requestHealthCheck { _ in }
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopContinuousHealthMonitoring() {
        healthTimer?.setEventHandler {}
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func handleHealthResult(_ snapshot: TunnelHealthSnapshot) {
        healthLock.lock()
        if snapshot.healthy {
            consecutiveHealthFailures = 0
            healthLock.unlock()
            return
        }
        consecutiveHealthFailures += 1
        let shouldCancel = consecutiveHealthFailures >= 3
        healthLock.unlock()
        guard shouldCancel, !isTunnelStopping() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTunnelStopping() else { return }
            self.failTunnel(self.tunnelError(snapshot.failureReason ?? "Tunnel health failed"))
        }
    }

    private func runtimeSnapshotData() -> Data? {
        let snapshot = sharedStateStore?.snapshot() ?? TunnelRuntimeSnapshot(session: nil, health: nil)
        return snapshot.jsonData()
    }

    private func persistSession(running: Bool) {
        guard !tunnelSessionId.isEmpty else { return }
        let stats = Socks5Tunnel.stats
        sharedStateStore?.save(session: TunnelSessionSnapshot(
            sessionId: tunnelSessionId,
            startedAtMilliseconds: tunnelStartedAtMilliseconds,
            running: running,
            uploadBytes: counterValue(stats.up.bytes),
            downloadBytes: counterValue(stats.down.bytes)
        ))
    }

    private func persistHealth(healthy: Bool, failureReason: String) {
        let flags = runtimeFlags()
        let snapshot = TunnelHealthSnapshot(
            sessionId: tunnelSessionId,
            healthy: healthy,
            xrayRunning: flags.xray,
            hevRunning: flags.hev,
            socksInboundReady: false,
            httpStatusCode: nil,
            httpStatusLine: "",
            failureReason: failureReason
        )
        sharedStateStore?.save(health: snapshot)
    }

    private func counterValue(_ value: Any) -> Int64 {
        max(0, Int64(String(describing: value)) ?? 0)
    }

    private func failTunnel(_ error: Error) {
        lifecycleLock.lock()
        let alreadyStopping = tunnelStopping
        tunnelStopping = true
        lifecycleLock.unlock()
        guard !alreadyStopping else { return }

        rememberTunnelLog("Cancelling packet tunnel: \(error.localizedDescription)")
        invalidateHealthChecks()
        stopContinuousHealthMonitoring()
        persistSession(running: false)
        persistHealth(healthy: false, failureReason: error.localizedDescription)
        stopRuntime()
        cancelTunnelWithError(error)
    }

    private func stopRuntime() {
        stopHevRuntime()
        stopXRay()
    }

    private func scheduleHevStart() -> UInt64? {
        guard !isTunnelStopping() else { return nil }
        hevLifecycleLock.lock()
        defer { hevLifecycleLock.unlock() }
        guard !isTunnelStopping() else { return nil }
        hevGeneration &+= 1
        hevLifecycleState = .scheduled
        return hevGeneration
    }

    private func beginHevRun(generation: UInt64) -> Bool {
        hevLifecycleLock.lock()
        guard generation == hevGeneration,
              hevLifecycleState == .scheduled,
              !isTunnelStopping() else {
            hevLifecycleLock.unlock()
            return false
        }
        hevLifecycleState = .running
        hevLifecycleLock.unlock()
        setHevRunning(true)

        // stopTunnel may have won immediately after the state transition. In
        // that case do not enter the blocking native run loop.
        guard !isTunnelStopping(), isCurrentHevGeneration(generation) else {
            _ = finishHevRun(generation: generation)
            return false
        }
        return true
    }

    @discardableResult
    private func finishHevRun(generation: UInt64) -> Bool {
        hevLifecycleLock.lock()
        let isCurrent = generation == hevGeneration
        if isCurrent {
            hevLifecycleState = .idle
        }
        hevLifecycleLock.unlock()
        if isCurrent {
            setHevRunning(false)
        }
        return isCurrent
    }

    private func stopHevRuntime() {
        hevLifecycleLock.lock()
        let shouldQuit = hevLifecycleState == .running
        hevGeneration &+= 1
        let stopGeneration = hevGeneration
        hevLifecycleState = .stopping
        hevLifecycleLock.unlock()
        setHevRunning(false)

        if shouldQuit {
            Socks5Tunnel.quit()
        }
        // Covers the narrow transition between the final start check and the
        // native blocking call. A newer tunnel increments the generation and
        // is therefore never affected by this delayed quit.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isHevStopping(generation: stopGeneration) else { return }
            Socks5Tunnel.quit()
        }
    }

    private func isCurrentHevGeneration(_ generation: UInt64) -> Bool {
        hevLifecycleLock.lock()
        defer { hevLifecycleLock.unlock() }
        return generation == hevGeneration && hevLifecycleState == .running
    }

    private func isHevStopping(generation: UInt64) -> Bool {
        hevLifecycleLock.lock()
        defer { hevLifecycleLock.unlock() }
        return generation == hevGeneration && hevLifecycleState == .stopping
    }

    private func setXrayRunning(_ value: Bool) {
        healthLock.lock()
        xrayRunning = value
        healthLock.unlock()
    }

    private func isXrayRunning() -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return xrayRunning
    }

    private func setHevRunning(_ value: Bool) {
        healthLock.lock()
        hevRunning = value
        healthLock.unlock()
    }

    private func isHevRunning() -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return hevRunning
    }

    private func runtimeFlags() -> (xray: Bool, hev: Bool) {
        healthLock.lock()
        defer { healthLock.unlock() }
        return (xrayRunning, hevRunning)
    }

    private func beginHealthGeneration() {
        healthLock.lock()
        healthGeneration &+= 1
        consecutiveHealthFailures = 0
        healthLock.unlock()
    }

    private func invalidateHealthChecks() {
        healthLock.lock()
        healthGeneration &+= 1
        healthLock.unlock()
    }

    private func cancelledHealthSnapshot() -> TunnelHealthSnapshot {
        let flags = runtimeFlags()
        return TunnelHealthSnapshot(
            sessionId: tunnelSessionId,
            healthy: false,
            xrayRunning: flags.xray,
            hevRunning: flags.hev,
            socksInboundReady: false,
            httpStatusCode: nil,
            httpStatusLine: "",
            failureReason: "Health check was cancelled because the tunnel is stopping"
        )
    }

    private func readHevLogTail() -> String? {
        guard let hevLogURL else { return nil }
        TunnelRotatingLog.rotateIfNeeded(at: hevLogURL)
        return TunnelRotatingLog.tail(at: hevLogURL)
    }

    private func buildIPv6ExcludedRoutes(serverAddress: String?) -> [NEIPv6Route] {
        guard let serverAddress else { return [] }
        let serverAddresses = TunnelRuntimePolicy.proxyEndpointExclusions(
            resolveIPv6Addresses(for: serverAddress)
        )
        let routes = serverAddresses.map {
            NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128)
        }
        if !routes.isEmpty {
            tunnelLog.info("Excluded \(routes.count, privacy: .public) IPv6 server route(s) from VPN: \(serverAddresses.joined(separator: ","), privacy: .public)")
        }
        return routes
    }

    private func ipv4Route(fromCIDR cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let subnetMask = subnetMask(prefixLength: prefix) else {
            tunnelLog.warning("Ignoring invalid IPv4 bypass subnet: \(cidr, privacy: .public)")
            return nil
        }
        let address = String(parts[0])
        guard isIPv4Literal(address) else {
            tunnelLog.warning("Ignoring non-IPv4 bypass subnet: \(cidr, privacy: .public)")
            return nil
        }
        return NEIPv4Route(destinationAddress: address, subnetMask: subnetMask)
    }

    private func subnetMask(prefixLength: Int) -> String? {
        guard (0...32).contains(prefixLength) else { return nil }
        let mask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
        return [
            (mask >> 24) & 0xff,
            (mask >> 16) & 0xff,
            (mask >> 8) & 0xff,
            mask & 0xff
        ].map(String.init).joined(separator: ".")
    }

    private func resolveIPv4Addresses(for host: String) -> [String] {
        if isIPv4Literal(host) {
            return [host]
        }
        return resolveAddresses(for: host, family: AF_INET)
    }

    private func resolveIPv6Addresses(for host: String) -> [String] {
        if isIPv6Literal(host) {
            return [host]
        }
        return resolveAddresses(for: host, family: AF_INET6)
    }

    private func resolveAddresses(for host: String, family: Int32) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: family,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            tunnelLog.warning("Failed to resolve \(host, privacy: .public): \(String(cString: gai_strerror(status)), privacy: .public)")
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            if current.pointee.ai_family == AF_INET {
                var addr = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    addresses.append(String(cString: buffer))
                }
            } else if current.pointee.ai_family == AF_INET6 {
                var addr = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    addresses.append(String(cString: buffer))
                }
            }
            pointer = current.pointee.ai_next
        }
        return Array(Set(addresses)).sorted()
    }

    private func isIPv4Literal(_ address: String) -> Bool {
        var addr = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private func isIPv6Literal(_ address: String) -> Bool {
        var addr = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    private func tunnelError(_ message: String) -> NSError {
        tunnelLog.error("\(message, privacy: .public)")
        return NSError(domain: "flutter_vless.packet_tunnel", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private func setTunnelStopping(_ value: Bool) {
        lifecycleLock.lock()
        tunnelStopping = value
        lifecycleLock.unlock()
    }

    private func isTunnelStopping() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return tunnelStopping
    }

    private func logTrafficStats(context: String) {
        guard Date().timeIntervalSince(lastTrafficLogDate) >= providerTrafficLogInterval || context != "poll" else {
            return
        }
        lastTrafficLogDate = Date()
        let stats = Socks5Tunnel.stats
        rememberTunnelLog("Traffic \(context): upPackets=\(stats.up.packets) upBytes=\(stats.up.bytes) downPackets=\(stats.down.packets) downBytes=\(stats.down.bytes)")
        #if DEBUG
        tunnelLog.info("Traffic stats context=\(context, privacy: .public) upPackets=\(stats.up.packets, privacy: .public) upBytes=\(stats.up.bytes, privacy: .public) downPackets=\(stats.down.packets, privacy: .public) downBytes=\(stats.down.bytes, privacy: .public)")
        #else
        if context != "poll" {
            tunnelLog.info("Traffic totals recorded while stopping packet tunnel")
        }
        #endif
    }
}


class CustomXRayLogger: NSObject, XRayLoggerProtocol {
    func logInput(_ s: String?) {
        if let logMessage = s {
            #if DEBUG
            TunnelDebugStore.shared.append("XRay: \(logMessage)")
            tunnelLog.info("XRay: \(logMessage, privacy: .public)")
            #else
            let normalized = logMessage.lowercased()
            if normalized.contains("error") ||
                normalized.contains("failed") ||
                normalized.contains("fatal") {
                TunnelDebugStore.shared.append("XRay: \(logMessage)")
                tunnelLog.error("XRay: \(logMessage, privacy: .public)")
            }
            #endif
        }
    }
}
