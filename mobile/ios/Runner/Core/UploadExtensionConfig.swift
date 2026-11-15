import Flutter
import Photos

/// Channel `immich/upload_extension`: what the Photos background-upload extension (ios/UploadExtension) should
/// upload. Keys and file name are shared with UploadExtension.swift.
enum UploadExtensionConfig {
  static let configFile = "upload-extension.json"
  static let pausedKey = "upload_extension_paused"
  private static let resetKey = "upload_extension_reset_1"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "immich/upload_extension", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "configure":
        result(configure(call.arguments as? [String: Any] ?? [:]))
      case "isEnabled":
        if #available(iOS 26.1, *) { result(PHPhotoLibrary.shared().uploadJobExtensionEnabled) } else { result(false) }
      case "setQueued":
        // Assets the app just queued on its own background URLSession; the extension leaves them out.
        UserDefaults.group.set(call.arguments as? [String] ?? [], forKey: "upload_extension_queued")
        result(nil)
      case "setPaused":
        UserDefaults.group.set(call.arguments as? Bool ?? true, forKey: pausedKey)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Adds a line to the extension's log (`upload-extension.log`), so both sides read in one place.
  private static func appendLog(_ dir: URL, _ message: String) {
    let file = dir.appendingPathComponent("upload-extension.log")
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: file)
    }
  }

  /// Writes the candidate list and enables the extension. Returns nil when enabled, otherwise why not.
  private static func configure(_ args: [String: Any]) -> String? {
    guard #available(iOS 26.1, *) else { return "needs iOS 26.1" }
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP)
    else { return "no app group container" }
    var config = args
    // Assets added to the library after this point are picked up too (see UploadExtension.addedAssets).
    config["since"] = Date().timeIntervalSince1970
    if let token = try? NSKeyedArchiver.archivedData(
      withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    {
      config["changeToken"] = token.base64EncodedString()
    }
    do {
      try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent(configFile), options: .atomic)
      // A fresh list gets a fresh try (server down, route missing). In-flight ids stay: those jobs are still queued.
      UserDefaults.group.removeObject(forKey: "upload_extension_failed")
      let library = PHPhotoLibrary.shared()
      // One-time reset: an earlier build left Photos waiting on a job whose photo was deleted, so it never called
      // the extension again. Switching the extension off and on clears that; the stale in-flight ids go with it.
      if library.uploadJobExtensionEnabled && !UserDefaults.group.bool(forKey: resetKey) {
        try library.setUploadJobExtensionEnabled(false)
        UserDefaults.group.removeObject(forKey: "upload_extension_inflight")
        UserDefaults.group.set(true, forKey: resetKey)
        appendLog(dir, "app: reset the extension (switched off and on)")
      }
      if !library.uploadJobExtensionEnabled {
        try library.setUploadJobExtensionEnabled(true)
      }
      return library.uploadJobExtensionEnabled ? nil : "enable returned without error but the extension is not active"
    } catch {
      return "\(error)"
    }
  }
}
