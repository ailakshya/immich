import ActivityKit
import Flutter
import Photos
import UIKit

// ponytail: duplicated in WidgetExtension/widgets/BackupLiveActivity.swift; ActivityKit matches by type name + Codable shape.
struct BackupActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var done: Int
    var total: Int
    var paused: Bool
    var detail: String?  // "12.3 MB/s · ~1h 5m left"
    var file: String?  // file uploading now (foreground only)
    var fileProgress: Double?
    var updatedAt: Date?  // when the app last pushed this state
  }
}

/// Lock screen / Dynamic Island backup progress, driven from Dart over `immich/backup_live_activity`.
/// update(done, total, paused, start): updates the activity, creating it only when `start` is true.
/// end(done, total): ends it, lingering 2 min when complete.
/// isEnabled / setEnabled(bool): the backup-settings switch; off ends any activity and ignores updates.
enum BackupLiveActivity {
  /// Set from the "Progress on Lock Screen" switch in backup settings.
  private static let disabledKey = "backup_live_activity_disabled"

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "immich/backup_live_activity", binaryMessenger: messenger).setMethodCallHandler {
      call, result in
      switch call.method {
      case "isEnabled":
        return result(!UserDefaults.standard.bool(forKey: disabledKey))
      case "setEnabled":
        let enabled = call.arguments as? Bool ?? true
        UserDefaults.standard.set(!enabled, forKey: disabledKey)
        if !enabled, #available(iOS 16.2, *) {
          Task {
            for activity in Activity<BackupActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
          }
        }
        return result(nil)
      default:
        break
      }
      guard #available(iOS 16.2, *), let a = call.arguments as? [String: Any] else { return result(nil) }
      if UserDefaults.standard.bool(forKey: disabledKey) { return result(nil) } // switched off in backup settings
      let state = BackupActivityAttributes.ContentState(
        done: a["done"] as? Int ?? 0, total: a["total"] as? Int ?? 0, paused: a["paused"] as? Bool ?? false,
        detail: a["detail"] as? String, file: a["file"] as? String, fileProgress: a["fileProgress"] as? Double,
        updatedAt: Date())
      let start = a["start"] as? Bool ?? false
      Task {
        await apply(call.method, state, start: start)
        result(nil)
      }
    }
  }

  @available(iOS 16.2, *)
  private static func apply(_ method: String, _ state: BackupActivityAttributes.ContentState, start: Bool) async {
    let content = ActivityContent(state: state, staleDate: nil)
    let activities = Activity<BackupActivityAttributes>.activities
    if method == "end" {
      let policy: ActivityUIDismissalPolicy = state.done >= state.total ? .after(.now + 120) : .immediate
      for activity in activities { await activity.end(content, dismissalPolicy: policy) }
    } else if let activity = activities.first {
      await activity.update(content)
    } else if start, ActivityAuthorizationInfo().areActivitiesEnabled {
      _ = try? Activity.request(attributes: BackupActivityAttributes(), content: content)
    }
  }
}

/// Background execution time requested from Dart (`immich/background_time`: begin / end).
/// The app uses the scene lifecycle, so `applicationDidEnterBackground` never fires; Dart asks when its pause handler runs.
enum BackgroundTime {
  private static var task = UIBackgroundTaskIdentifier.invalid

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "immich/background_time", binaryMessenger: messenger).setMethodCallHandler { call, result in
      let app = UIApplication.shared
      if task != .invalid {
        app.endBackgroundTask(task)
        task = .invalid
      }
      if call.method == "begin" {
        task = app.beginBackgroundTask(withName: "immich.handoff") {
          app.endBackgroundTask(task)
          task = .invalid
        }
      }
      result(nil)
    }
  }
}

/// `immich/asset_sizes`: total([localIds]) -> summed bytes of the originals that get uploaded (photo/video + live-photo
/// video); freeSpace() -> bytes available for important usage.
enum AssetSizes {
  private static let uploaded: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo]

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "immich/asset_sizes", binaryMessenger: messenger).setMethodCallHandler { call, result in
      if call.method == "freeSpace" {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
          .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return result(values?.volumeAvailableCapacityForImportantUsage ?? 0)
      }
      guard let ids = call.arguments as? [String] else { return result(0) }
      DispatchQueue.global(qos: .utility).async {
        var total: Int64 = 0
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
          for resource in PHAssetResource.assetResources(for: asset) where uploaded.contains(resource.type) {
            // ponytail: "fileSize" is undocumented KVC but stable for years; 0 if Apple ever drops it.
            total += (resource.value(forKey: "fileSize") as? Int64) ?? 0
          }
        }
        DispatchQueue.main.async { result(total) }
      }
    }
  }
}
