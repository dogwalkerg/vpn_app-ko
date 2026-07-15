import XCTest

final class MacOSProxyPolicyTests: XCTestCase {
  private var completeConfiguration: [String: Any] {
    [
      "HTTPEnable": 1,
      "HTTPProxy": "127.0.0.1",
      "HTTPPort": 7890,
      "HTTPSEnable": 1,
      "HTTPSProxy": "127.0.0.1",
      "HTTPSPort": 7890,
      "SOCKSEnable": 1,
      "SOCKSProxy": "127.0.0.1",
      "SOCKSPort": 7890,
      "ProxyAutoConfigEnable": 0,
      "ProxyAutoDiscoveryEnable": 0,
      "ExceptionsList": [String](),
      "ExcludeSimpleHostnames": 0,
    ]
  }

  func testStrictCaptureAcceptsCompleteLocalConfiguration() {
    XCTAssertTrue(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: completeConfiguration,
      protocolEnabled: true
    ))
  }

  func testStrictCaptureRequiresAllThreeProxyTypes() {
    var configuration = completeConfiguration
    configuration["SOCKSEnable"] = 0
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))

    configuration = completeConfiguration
    configuration["HTTPSPort"] = 7891
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))
  }

  func testStrictCaptureRejectsPACAndAutoDiscovery() {
    var configuration = completeConfiguration
    configuration["ProxyAutoConfigEnable"] = 1
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))

    configuration = completeConfiguration
    configuration["ProxyAutoDiscoveryEnable"] = 1
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))
  }

  func testStrictCaptureRejectsEveryBypassForm() {
    var configuration = completeConfiguration
    configuration["ExceptionsList"] = ["*.local"]
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))

    configuration = completeConfiguration
    configuration["ExcludeSimpleHostnames"] = 1
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))

    configuration = completeConfiguration
    configuration["ExceptionsList"] = "*.local"
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: configuration,
      protocolEnabled: true
    ))
  }

  func testStrictCaptureRequiresProtocolToBeEnabled() {
    XCTAssertFalse(MacOSProxyPolicy.isStrictlyCaptured(
      configuration: completeConfiguration,
      protocolEnabled: false
    ))
  }

  func testEveryActiveServiceMustBeCaptured() {
    XCTAssertFalse(MacOSProxyPolicy.allApplicableServicesCaptured([
      ["active": true, "enabled": true, "usesLocalCore": true],
      ["active": true, "enabled": true, "usesLocalCore": false],
      ["active": false, "enabled": true, "usesLocalCore": true],
    ]))
    XCTAssertTrue(MacOSProxyPolicy.allApplicableServicesCaptured([
      ["active": true, "enabled": true, "usesLocalCore": true],
      ["active": false, "enabled": true, "usesLocalCore": false],
    ]))
    XCTAssertFalse(MacOSProxyPolicy.allApplicableServicesCaptured([
      ["active": true, "enabled": false, "usesLocalCore": true],
    ]))
  }

  func testEnabledServicesAreFallbackWhenActiveServiceIsUnavailable() {
    XCTAssertFalse(MacOSProxyPolicy.allApplicableServicesCaptured([]))
    XCTAssertFalse(MacOSProxyPolicy.allApplicableServicesCaptured([
      ["active": false, "enabled": true, "usesLocalCore": true],
      ["active": false, "enabled": true, "usesLocalCore": false],
      ["active": false, "enabled": false, "usesLocalCore": false],
    ]))
    XCTAssertTrue(MacOSProxyPolicy.allApplicableServicesCaptured([
      ["active": false, "enabled": true, "usesLocalCore": true],
      ["active": false, "enabled": false, "usesLocalCore": false],
    ]))
  }

  func testThreeWayRestoreReturnsUntouchedManagedFieldsToOriginalValues() {
    let original: [String: Any] = [
      "HTTPEnable": 1,
      "HTTPProxy": "original-http.example",
      "HTTPPort": 8080,
      "HTTPSEnable": 0,
      "HTTPSProxy": "original-https.example",
      "HTTPSPort": 8443,
      "SOCKSEnable": 1,
      "SOCKSProxy": "original-socks.example",
      "SOCKSPort": 1080,
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "https://original.example/proxy.pac",
      "ProxyAutoDiscoveryEnable": 1,
      "ExceptionsList": ["*.original.example"],
      "ExcludeSimpleHostnames": 1,
    ]
    let managed = MacOSProxyPolicy.managedConfiguration(from: original)

    let merge = MacOSProxyPolicy.mergeConfigurationForRestore(
      original: original,
      current: managed
    )

    XCTAssertTrue(merge.conflicts.isEmpty)
    XCTAssertTrue(
      NSDictionary(dictionary: merge.configuration).isEqual(to: original)
    )
  }

  func testThreeWayRestorePreservesUserChangesAcrossEveryManagedCategory() {
    let original: [String: Any] = [
      "HTTPEnable": 1,
      "HTTPProxy": "original-http.example",
      "HTTPPort": 8080,
      "HTTPSEnable": 1,
      "HTTPSProxy": "original-https.example",
      "HTTPSPort": 8443,
      "SOCKSEnable": 1,
      "SOCKSProxy": "original-socks.example",
      "SOCKSPort": 1080,
      "ProxyAutoConfigEnable": 0,
      "ProxyAutoConfigURLString": "https://original.example/proxy.pac",
      "ProxyAutoDiscoveryEnable": 0,
      "ExceptionsList": ["*.original.example"],
      "ExcludeSimpleHostnames": 0,
    ]
    var current = MacOSProxyPolicy.managedConfiguration(from: original)
    current["HTTPEnable"] = 0
    current["HTTPProxy"] = "user-http.example"
    current["HTTPSProxy"] = "user-https.example"
    current["SOCKSPort"] = 9999
    current["ProxyAutoConfigEnable"] = 1
    current["ProxyAutoConfigURLString"] = "https://user.example/proxy.pac"
    current["ProxyAutoDiscoveryEnable"] = 1
    current["ExceptionsList"] = ["*.user.example"]
    current["ExcludeSimpleHostnames"] = 1

    let merge = MacOSProxyPolicy.mergeConfigurationForRestore(
      original: original,
      current: current
    )

    XCTAssertEqual(merge.configuration["HTTPEnable"] as? Int, 0)
    XCTAssertEqual(merge.configuration["HTTPProxy"] as? String, "user-http.example")
    XCTAssertEqual(merge.configuration["HTTPPort"] as? Int, 8080)
    XCTAssertEqual(merge.configuration["HTTPSProxy"] as? String, "user-https.example")
    XCTAssertEqual(merge.configuration["HTTPSPort"] as? Int, 8443)
    XCTAssertEqual(merge.configuration["SOCKSPort"] as? Int, 9999)
    XCTAssertEqual(merge.configuration["SOCKSProxy"] as? String, "original-socks.example")
    XCTAssertEqual(merge.configuration["ProxyAutoConfigEnable"] as? Int, 1)
    XCTAssertEqual(
      merge.configuration["ProxyAutoConfigURLString"] as? String,
      "https://user.example/proxy.pac"
    )
    XCTAssertEqual(merge.configuration["ProxyAutoDiscoveryEnable"] as? Int, 1)
    XCTAssertEqual(
      merge.configuration["ExceptionsList"] as? [String],
      ["*.user.example"]
    )
    XCTAssertEqual(merge.configuration["ExcludeSimpleHostnames"] as? Int, 1)
    XCTAssertEqual(
      Set(merge.conflicts),
      Set([
        "HTTPEnable",
        "HTTPProxy",
        "HTTPSProxy",
        "SOCKSPort",
        "ProxyAutoConfigEnable",
        "ProxyAutoDiscoveryEnable",
        "ExceptionsList",
        "ExcludeSimpleHostnames",
      ])
    )
  }

  func testThreeWayRestorePreservesAUserDisabledProtocol() {
    let merge = MacOSProxyPolicy.mergeProtocolEnabledForRestore(
      original: true,
      current: false
    )
    XCTAssertFalse(merge.enabled)
    XCTAssertTrue(merge.conflict)
  }

  func testThreeWayRestoreDisablesAProtocolEnabledOnlyByOsca() {
    let merge = MacOSProxyPolicy.mergeProtocolEnabledForRestore(
      original: false,
      current: true
    )
    XCTAssertFalse(merge.enabled)
    XCTAssertFalse(merge.conflict)
  }
}
