import XCTest
@testable import flutter_vless_tunnel_support

final class TunnelRuntimeSupportTests: XCTestCase {
    func testRuntimeRemainsReadyWhenPublicProbeFails() {
        let snapshot = makeSnapshot(
            healthy: false,
            xrayRunning: true,
            hevRunning: true,
            socksInboundReady: true,
            failureReason: "Public health probe timed out"
        )

        XCTAssertFalse(snapshot.healthy)
        XCTAssertTrue(snapshot.runtimeReady)
    }

    func testRuntimeIsNotReadyWhenAnyNativeComponentFails() {
        let unavailableComponents: [(name: String, xray: Bool, hev: Bool, socks: Bool)] = [
            ("Xray", false, true, true),
            ("HEV", true, false, true),
            ("SOCKS", true, true, false)
        ]

        for component in unavailableComponents {
            let snapshot = makeSnapshot(
                healthy: false,
                xrayRunning: component.xray,
                hevRunning: component.hev,
                socksInboundReady: component.socks,
                failureReason: "\(component.name) is not ready"
            )

            XCTAssertFalse(
                snapshot.runtimeReady,
                "Runtime must not be ready when \(component.name) is unavailable"
            )
        }
    }

    private func makeSnapshot(
        healthy: Bool,
        xrayRunning: Bool,
        hevRunning: Bool,
        socksInboundReady: Bool,
        failureReason: String?
    ) -> TunnelHealthSnapshot {
        TunnelHealthSnapshot(
            sessionId: "health-policy-test",
            healthy: healthy,
            xrayRunning: xrayRunning,
            hevRunning: hevRunning,
            socksInboundReady: socksInboundReady,
            httpStatusCode: nil,
            httpStatusLine: "",
            failureReason: failureReason,
            checkedAtMilliseconds: 1_000
        )
    }
}
