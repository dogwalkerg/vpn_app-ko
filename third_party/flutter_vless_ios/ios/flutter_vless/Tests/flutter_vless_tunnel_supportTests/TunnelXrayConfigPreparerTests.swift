import XCTest
@testable import flutter_vless_tunnel_support

final class TunnelXrayConfigPreparerTests: XCTestCase {
    func testPreparesXhttpNoneWithoutDroppingVlessEncryption() throws {
        let input = try jsonData([
            "dns": ["queryStrategy": "UseIPv4"],
            "log": [
                "access": "/desktop/access.log",
                "error": "/desktop/error.log",
                "loglevel": "warning",
                "dnsLog": true
            ],
            "inbounds": [
                [
                    "tag": "socks-in",
                    "listen": "127.0.0.1",
                    "port": 10808,
                    "protocol": "socks",
                    "settings": ["auth": "noauth", "udp": true]
                ]
            ],
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": "proxy.example.com",
                                "port": 2043,
                                "users": [
                                    [
                                        "id": "b94da146-a56e-49d7-af4c-a68c9065cbfd",
                                        "encryption": Self.vlessEncryption,
                                        "level": 8,
                                        "security": "auto"
                                    ]
                                ]
                            ]
                        ]
                    ],
                    "streamSettings": [
                        "network": "XHTTP",
                        "security": "none",
                        "tlsSettings": ["allowInsecure": false],
                        "xHTTPSettings": [
                            "host": "s3.storage.selcloud.ru",
                            "path": "/my-bucket",
                            "mode": "stream-up"
                        ],
                        "sockopt": ["domainStrategy": "UseIP"]
                    ]
                ],
                ["tag": "direct", "protocol": "freedom"],
                ["tag": "block", "protocol": "blackhole"]
            ],
            "routing": ["domainStrategy": "IPIfNonMatch", "rules": []]
        ])

        let result = try XCTUnwrap(TunnelXrayConfigPreparer.prepare(jsonData: input))
        let output = try decodedObject(result.data)
        let log = try XCTUnwrap(output["log"] as? [String: Any])
        let routing = try XCTUnwrap(output["routing"] as? [String: Any])
        let inbounds = try XCTUnwrap(output["inbounds"] as? [[String: Any]])
        let outbounds = try XCTUnwrap(output["outbounds"] as? [[String: Any]])
        let proxy = outbounds[0]
        let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
        let vnext = try XCTUnwrap(settings["vnext"] as? [[String: Any]])
        let users = try XCTUnwrap(vnext[0]["users"] as? [[String: Any]])
        let streamSettings = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
        let rules = try XCTUnwrap(routing["rules"] as? [[String: Any]])

        XCTAssertTrue(result.proxyUsesXhttp)
        XCTAssertEqual(log["access"] as? String, "")
        XCTAssertEqual(log["error"] as? String, "")
        XCTAssertTrue(["debug", "warning"].contains(log["loglevel"] as? String ?? ""))
        XCTAssertEqual(log["dnsLog"] as? Bool, false)
        XCTAssertNil(output["dns"])
        XCTAssertEqual(routing["domainStrategy"] as? String, "AsIs")
        XCTAssertEqual(users[0]["encryption"] as? String, Self.vlessEncryption)
        XCTAssertEqual(vnext[0]["address"] as? String, "proxy.example.com")
        XCTAssertEqual(streamSettings["network"] as? String, "xhttp")
        XCTAssertNil(streamSettings["xHTTPSettings"])
        XCTAssertNotNil(streamSettings["xhttpSettings"])
        XCTAssertNil((streamSettings["tlsSettings"] as? [String: Any])?["allowInsecure"])
        XCTAssertNil(streamSettings["sockopt"])
        XCTAssertEqual(rules.first?["network"] as? String, "udp")
        XCTAssertEqual(String(describing: rules.first?["port"] ?? ""), "443")
        XCTAssertEqual(rules.first?["outboundTag"] as? String, "block")

        let sniffing = try XCTUnwrap(inbounds[0]["sniffing"] as? [String: Any])
        XCTAssertEqual(sniffing["enabled"] as? Bool, true)
        XCTAssertEqual(sniffing["routeOnly"] as? Bool, false)
        XCTAssertEqual(sniffing["destOverride"] as? [String], ["http", "tls", "quic"])
    }

    func testResolvesNonXhttpNoneProxyDomainsForRouteBootstrap() throws {
        let input = try jsonData([
            "inbounds": [["port": 10807, "protocol": "socks"]],
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": "reality.example.com",
                                "port": 443,
                                "users": [["id": "b94da146-a56e-49d7-af4c-a68c9065cbfd", "encryption": "none"]]
                            ]
                        ]
                    ],
                    "streamSettings": ["network": "tcp", "security": "reality"]
                ]
            ]
        ])

        let result = try XCTUnwrap(TunnelXrayConfigPreparer.prepare(jsonData: input) { host in
            host == "reality.example.com" ? "203.0.113.10" : nil
        })
        let output = try decodedObject(result.data)
        let proxy = try XCTUnwrap((output["outbounds"] as? [[String: Any]])?.first)
        let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
        let vnext = try XCTUnwrap(settings["vnext"] as? [[String: Any]])

        XCTAssertFalse(result.proxyUsesXhttp)
        XCTAssertEqual(vnext[0]["address"] as? String, "203.0.113.10")
        XCTAssertTrue(result.logMessages.contains("Resolved proxy server domain to IPv4 in Xray config"))
    }

    func testParsesInboundPortAndProxyServerAcrossProtocols() throws {
        let shadowsocks = try jsonData([
            "inbounds": [
                ["port": 10000, "protocol": "dokodemo-door"],
                ["port": 10820, "protocol": "http"]
            ],
            "outbounds": [
                ["tag": "direct", "protocol": "freedom"],
                [
                    "tag": "proxy",
                    "protocol": "shadowsocks",
                    "settings": [
                        "servers": [["address": "ss.example.com", "port": 8388]]
                    ]
                ]
            ]
        ])

        XCTAssertEqual(
            TunnelXrayConfigPreparer.parseConfig(jsonData: shadowsocks),
            TunnelParsedConfig(inboundPort: 10820, serverAddress: "ss.example.com")
        )
    }

    func testKeepsUdp443RuleIdempotent() throws {
        let input = try jsonData([
            "inbounds": [["port": 10807, "protocol": "socks"]],
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": "proxy.example.com",
                                "port": 2043,
                                "users": [["id": "b94da146-a56e-49d7-af4c-a68c9065cbfd", "encryption": "none"]]
                            ]
                        ]
                    ],
                    "streamSettings": ["network": "xhttp", "security": "none"]
                ],
                ["tag": "blackhole", "protocol": "blackhole"]
            ],
            "routing": [
                "rules": [
                    [
                        "type": "field",
                        "network": "udp",
                        "port": "443",
                        "outboundTag": "blackhole"
                    ]
                ]
            ]
        ])

        let result = try XCTUnwrap(TunnelXrayConfigPreparer.prepare(jsonData: input))
        let output = try decodedObject(result.data)
        let routing = try XCTUnwrap(output["routing"] as? [String: Any])
        let rules = try XCTUnwrap(routing["rules"] as? [[String: Any]])

        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(result.logMessages.contains("Added XHTTP UDP/443 block rule to force browser TCP fallback"))
    }

    func testKeepsXhttpNoneDomainForXrayResolution() throws {
        let input = try jsonData([
            "inbounds": [["port": 10807, "protocol": "socks"]],
            "outbounds": [[
                "tag": "proxy",
                "protocol": "vless",
                "settings": [
                    "vnext": [[
                        "address": "bootstrap.example.com",
                        "port": 80,
                        "users": [["id": "b94da146-a56e-49d7-af4c-a68c9065cbfd", "encryption": "none"]]
                    ]]
                ],
                "streamSettings": [
                    "network": "xhttp",
                    "security": "none",
                    "xhttpSettings": ["path": "/tunnel"]
                ]
            ]]
        ])

        let result = try XCTUnwrap(TunnelXrayConfigPreparer.prepare(jsonData: input) { host in
            host == "bootstrap.example.com" ? "203.0.113.22" : nil
        })
        let output = try decodedObject(result.data)
        let proxy = try XCTUnwrap((output["outbounds"] as? [[String: Any]])?.first)
        let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
        let vnext = try XCTUnwrap(settings["vnext"] as? [[String: Any]])
        let stream = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
        let xhttp = try XCTUnwrap(stream["xhttpSettings"] as? [String: Any])

        XCTAssertEqual(vnext[0]["address"] as? String, "bootstrap.example.com")
        XCTAssertNil(xhttp["host"])
        XCTAssertTrue(result.logMessages.contains("Keeping XHTTP/none proxy domain in Xray config"))
    }

    func testHealthEvaluatorRequiresExact204() {
        let success = TunnelHTTPProbeEvaluator.evaluate(
            response: Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)
        )
        let redirected = TunnelHTTPProbeEvaluator.evaluate(
            response: Data("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n".utf8)
        )
        let malformed = TunnelHTTPProbeEvaluator.evaluate(response: Data("hello".utf8))

        XCTAssertTrue(success.success)
        XCTAssertEqual(success.statusCode, 204)
        XCTAssertFalse(redirected.success)
        XCTAssertEqual(redirected.statusCode, 302)
        XCTAssertEqual(redirected.failureReason, "Expected HTTP 204, received 302")
        XCTAssertFalse(malformed.success)
        XCTAssertNil(malformed.statusCode)
    }

    func testNetworkPolicyMatchesVerifiedV1035DataPath() {
        XCTAssertFalse(TunnelRuntimePolicy.routesDNSInsideTunnel)
        XCTAssertFalse(TunnelRuntimePolicy.capturesIPv6DefaultRoute)
        XCTAssertEqual(TunnelRuntimePolicy.dnsServers, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(TunnelRuntimePolicy.sessionPersistenceIntervalSeconds, 10)
    }

    func testSessionAndHealthSnapshotsRoundTrip() throws {
        let session = TunnelSessionSnapshot(
            sessionId: "session-a",
            startedAtMilliseconds: 1000,
            updatedAtMilliseconds: 2000,
            running: true,
            uploadBytes: 123,
            downloadBytes: 456
        )
        let health = TunnelHealthSnapshot(
            sessionId: "session-a",
            healthy: true,
            xrayRunning: true,
            hevRunning: true,
            socksInboundReady: true,
            httpStatusCode: 204,
            httpStatusLine: "HTTP/1.1 204 No Content",
            failureReason: nil,
            checkedAtMilliseconds: 3000
        )
        let encoded = try XCTUnwrap(TunnelRuntimeSnapshot(session: session, health: health).jsonData())
        let decoded = try JSONDecoder().decode(TunnelRuntimeSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.session, session)
        XCTAssertEqual(decoded.health, health)
    }

    func testSharedStateStoreRestoresSameNativeSession() throws {
        let suite = "flutter-vless-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(TunnelSharedStateStore(groupIdentifier: suite))
        let session = TunnelSessionSnapshot(
            sessionId: "native-session-stable-across-runner-restart",
            startedAtMilliseconds: 1000,
            updatedAtMilliseconds: 2000,
            running: true,
            uploadBytes: 4096,
            downloadBytes: 8192
        )
        first.save(session: session)

        let relaunchedRunner = try XCTUnwrap(TunnelSharedStateStore(groupIdentifier: suite))
        XCTAssertEqual(relaunchedRunner.loadSession(), session)
    }

    func testRotatingLogKeepsOnlyTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flutter-vless-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("0123456789abcdefghij".utf8).write(to: url)

        XCTAssertTrue(TunnelRotatingLog.rotateIfNeeded(
            at: url,
            maximumBytes: 10,
            retainedBytes: 6
        ))
        XCTAssertEqual(String(data: try Data(contentsOf: url), encoding: .utf8), "efghij")
    }

    private static let vlessEncryption =
        "mlkem768x25519plus.native.1rtt.100-500-2000.75-0-100.80-0-5000.gtmOXB2AN_r905czmOIr6dKq_YDdEJB8RWGqfsXurns"

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func decodedObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }
}
