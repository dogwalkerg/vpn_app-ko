import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var macOSProxyManager: MacOSProxyManager?
  private var macOSProxyChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let proxyManager = MacOSProxyManager()
    let proxyChannel = FlutterMethodChannel(
      name: MacOSProxyManager.channelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    proxyChannel.setMethodCallHandler { [weak proxyManager] call, result in
      guard let proxyManager else {
        result(FlutterError(
          code: "proxy_manager_unavailable",
          message: "The macOS proxy manager is unavailable",
          details: nil
        ))
        return
      }
      let arguments = call.arguments as? [String: Any] ?? [:]
      proxyManager.perform({
        switch call.method {
        case "read":
          return try proxyManager.readState()
        case "apply":
          let enabled = arguments["enabled"] as? Bool ?? false
          if enabled {
            let host = arguments["host"] as? String ?? "127.0.0.1"
            let port = (arguments["port"] as? NSNumber)?.intValue ?? 7890
            return try proxyManager.apply(host: host, port: port)
          }
          return try proxyManager.restore(
            force: arguments["force"] as? Bool ?? false
          )
        case "restore":
          return try proxyManager.restore(
            force: arguments["force"] as? Bool ?? false
          )
        case "validateCore":
          guard let path = arguments["path"] as? String else {
            throw MacOSProxyManagerError.invalidArguments(
              "The expected core executable path is required"
            )
          }
          let pid = (arguments["pid"] as? NSNumber)?.intValue
          return try proxyManager.validateCore(path: path, expectedPID: pid)
        default:
          throw FlutterMethodNotImplementedError()
        }
      }, completion: { response in
        switch response {
        case .success(let value):
          result(value)
        case .failure(let error as FlutterMethodNotImplementedError):
          _ = error
          result(FlutterMethodNotImplemented)
        case .failure(let error):
          result(FlutterError(
            code: "macos_proxy_error",
            message: error.localizedDescription,
            details: nil
          ))
        }
      })
    }
    macOSProxyManager = proxyManager
    macOSProxyChannel = proxyChannel

    super.awakeFromNib()
  }
}

private struct FlutterMethodNotImplementedError: Error {}
