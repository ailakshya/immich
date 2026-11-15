import ExtensionFoundation
import Foundation
import OSLog
import Photos

/// iOS 26.1+ Photos background-upload extension. Photos calls `process()` whenever it decides to, also while the
/// app is suspended or not running, and uploads the resources registered here as jobs by itself.
///
/// A job's body is the bare file, which Immich's multipart `POST /assets` can't take, so jobs go to
/// `<server>/api/assets/raw` with the upload fields in the query; a converter in front of the server (see
/// docs/docs/developer/ios-background-upload.md) forwards them as multipart.
///
/// What to upload comes from the app (`upload-extension.json`, written by UploadExtensionConfig.swift): the
/// candidate list plus photos created later in the selected albums. Login comes from the widget keys.
@main
struct UploadExtension: PHBackgroundResourceUploadExtension {
  init() {}

  func process() -> PHBackgroundResourceUploadProcessingResult {
    UploadQueue.process()
  }

  func notifyTermination() {
    UploadQueue.log("terminated by the system")
  }
}

private enum Keys {
  static let paused = "upload_extension_paused" // set by the app while it uploads in the foreground
  static let done = "upload_extension_done" // asset ids uploaded by the extension
  static let failed = "upload_extension_failed" // asset ids whose upload failed twice
  static let inflight = "upload_extension_inflight" // one asset id per registered job
  static let stateVersion = "upload_extension_state_version"
  static let pending = "upload_extension_pending" // added to the library, found by the extension, not yet registered
  static let queuedByApp = "upload_extension_queued" // on the app's own URLSession queue (set at each lock)
  static let changeToken = "upload_extension_change_token" // the extension's own position in Photos' change history
}

private struct Config: Decodable {
  let deviceId: String
  let candidates: [String]
  let albums: [String]
  let excluded: [String]
  let since: Double
  let changeToken: String?
  let checksums: [String: String]?
}

enum UploadQueue {
  private static let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as! String
  private static let logger = Logger(subsystem: "immich", category: "UploadExtension")

  static func process() -> PHBackgroundResourceUploadProcessingResult {
    guard let defaults = UserDefaults(suiteName: group),
      let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
      let data = try? Data(contentsOf: dir.appendingPathComponent("upload-extension.json")),
      let config = try? JSONDecoder().decode(Config.self, from: data),
      let server = defaults.string(forKey: "widget_server_url"), !server.isEmpty,
      let token = defaults.string(forKey: "widget_auth_token"), !token.isEmpty
    else {
      log("idle: not configured or logged out")
      return .completed
    }
    let library = PHPhotoLibrary.shared()
    var done = Set(defaults.stringArray(forKey: Keys.done) ?? [])
    var failed = Set(defaults.stringArray(forKey: Keys.failed) ?? [])
    var inflight = defaults.stringArray(forKey: Keys.inflight) ?? []
    var pending = defaults.stringArray(forKey: Keys.pending) ?? []
    if defaults.integer(forKey: Keys.stateVersion) < 2 {
      UploadPlan.migrateInflight(done: &done, inflight: &inflight)
      defaults.set(2, forKey: Keys.stateVersion)
      log("migrated state: \(done.count) done")
    }

    // 1. Finished jobs: retry each failure once, then acknowledge the rest to free their slots.
    do {
      let retry = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
      if retry.count > 0 {
        try library.performChangesAndWait {
          retry.enumerateObjects { job, _, _ in PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: nil) }
        }
      }
      let finished = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
      var succeeded = 0
      if finished.count > 0 {
        // Read the outcome first: an acknowledged job's record is gone from PhotoKit.
        var outcomes: [(String, Bool)] = []
        finished.enumerateObjects { job, _, _ in
          let id = UploadPlan.assetId(destination: job.destination.url) ?? job.resource.assetLocalIdentifier
          outcomes.append((id, job.state == .succeeded))
        }
        try library.performChangesAndWait {
          finished.enumerateObjects { job, _, _ in PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge() }
        }
        succeeded = outcomes.filter(\.1).count
        UploadPlan.settle(outcomes.map { (id: $0.0, ok: $0.1) }, done: &done, failed: &failed, inflight: &inflight)
      }
      log("acknowledged \(finished.count) (\(succeeded) ok), retried \(retry.count), \(inflight.count) in flight")
    } catch {
      log("acknowledge failed: \(error)")
    }
    // ponytail: uploaded ids drop out of the app's candidate list once it syncs; only trim when the set gets big
    // (trimming also forgets new photos uploaded since, which the server then reports as duplicates).
    if done.count > 20000 {
      done.formIntersection(config.candidates)
    }
    defer {
      defaults.set(Array(done), forKey: Keys.done)
      defaults.set(Array(failed), forKey: Keys.failed)
      defaults.set(inflight, forKey: Keys.inflight)
      defaults.set(pending, forKey: Keys.pending)
    }

    // A job whose photo was deleted never finishes; forget it so it does not hold anything back.
    let existing = existingAssets(Set(inflight))
    let before = inflight.count
    inflight = UploadPlan.prune(inflight, existing: existing)
    if inflight.count < before {
      log("dropped \(before - inflight.count) in-flight jobs for deleted photos")
    }

    // New photos are found here, without the app: Photos' change history since the extension's own bookmark.
    pending = UploadPlan.queue(added: pending, candidates: addedAssets(config, defaults: defaults), skip: [])

    if defaults.bool(forKey: Keys.paused) {
      log("paused: the app is uploading in the foreground")
      return .completed
    }

    // 2. Register the next assets: photos added to the library first, then the app's candidate list.
    let queuedByApp = Set(defaults.stringArray(forKey: Keys.queuedByApp) ?? [])
    let queue = UploadPlan.queue(
      added: pending, candidates: config.candidates, skip: done.union(failed).union(Set(inflight)).union(queuedByApp))
    // ponytail: our in-flight count can drift (a crash between registering and saving); always probe a few
    // slots. A full queue makes the whole change block fail with limitExceeded, so nothing is double-registered.
    var slots = max(PHAssetResourceUploadJob.jobLimit - inflight.count, 10)
    if queue.isEmpty {
      pending = []
      log("nothing to add, \(inflight.count) in flight")
      // .completed even with jobs in flight: .processing makes Photos wait for every queued job before calling us
      // again, so one job that never finishes (photo deleted, iCloud original unavailable) stalled all new photos.
      return .completed
    }

    let headers = customHeaders(defaults)
    // The app's list can be stale: assets it uploaded itself since then are on the server already.
    var checked = 0
    let (picked, onServer) = UploadPlan.pickNotOnServer(queue, want: slots) {
      checked += $0.count
      return alreadyOnServer($0, checksums: config.checksums ?? [:], server: server, token: token, headers: headers)
    }
    done.formUnion(onServer)
    log("server check: \(onServer.count) of \(checked) already on the server")
    let fetched = PHAsset.fetchAssets(withLocalIdentifiers: picked, options: nil)
    var assets: [String: PHAsset] = [:]
    fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
    var jobs: [(PHAssetResource, URLRequest)] = []
    for id in picked where slots > 0 {
      guard let asset = assets[id] else {
        failed.insert(id) // deleted from the library
        continue
      }
      let resources = uploadResources(asset)
      guard !resources.isEmpty, resources.count <= slots else { continue }
      for (index, resource) in resources.enumerated() {
        // The second resource is a live photo's video; the server pairs it by content identifier and hides it.
        guard let request = destination(server, token, headers, config.deviceId, asset, resource, hidden: index > 0)
        else { continue }
        jobs.append((resource, request))
        inflight.append(id)
      }
      slots -= resources.count
    }
    let registered = UploadPlan.register(
      jobs.count,
      attempt: { size in
        try library.performChangesAndWait {
          for (resource, request) in jobs.prefix(size) {
            PHAssetResourceUploadJobChangeRequest.createJob(destination: request, resource: resource)
          }
        }
      },
      isLimit: { ($0 as NSError).domain == PHPhotosErrorDomain && ($0 as NSError).code == PHPhotosError.limitExceeded.rawValue },
      log: log)
    // inflight holds one id per job, appended in order; drop those that were not registered.
    inflight.removeLast(jobs.count - registered)
    let handled = done.union(failed).union(Set(inflight)).union(queuedByApp)
    pending = pending.filter { !handled.contains($0) }
    let left = queue.filter { !handled.contains($0) }.count
    log("registered \(registered) of \(jobs.count) jobs, \(left) assets left, \(inflight.count) in flight")
    // .processing only while assets are left over (no free slots): Photos calls again once these jobs finish.
    return left == 0 ? .completed : .processing
  }

  /// Assets added to the library since the extension last looked (Photos' change history, so imports and saved
  /// photos with older dates count too), in the selected albums and not in an excluded one. The bookmark starts at
  /// the app's and then moves on with every run, so new photos are found without the app. Falls back to creation
  /// dates when the history is unavailable or expired.
  private static func addedAssets(_ config: Config, defaults: UserDefaults) -> [String] {
    let current = try? NSKeyedArchiver.archivedData(
      withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    let bookmark = defaults.string(forKey: Keys.changeToken) ?? config.changeToken
    defer {
      if let current { defaults.set(current.base64EncodedString(), forKey: Keys.changeToken) }
    }
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    if let added = insertedSince(bookmark) {
      log("library: \(added.count) added since the last look")
      guard !added.isEmpty else { return [] }
      options.predicate = NSPredicate(format: "localIdentifier IN %@", Array(added))
    } else {
      options.predicate = NSPredicate(format: "creationDate > %@", Date(timeIntervalSince1970: config.since) as NSDate)
    }
    func assets(in albumIds: [String]) -> [String] {
      guard !albumIds.isEmpty else { return [] }
      var ids: [String] = []
      PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIds, options: nil).enumerateObjects { album, _, _ in
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
      }
      return ids
    }
    let excluded = Set(assets(in: config.excluded))
    let picked = UploadPlan.queue(added: assets(in: config.albums), candidates: [], skip: excluded)
    log("library: \(picked.count) of them in backup albums")
    return picked
  }

  private static func existingAssets(_ ids: Set<String>) -> Set<String> {
    guard !ids.isEmpty else { return [] }
    var found = Set<String>()
    PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil).enumerateObjects { asset, _, _ in
      found.insert(asset.localIdentifier)
    }
    return found
  }

  /// Local identifiers inserted since the archived token, or nil when there is no usable history.
  private static func insertedSince(_ archived: String?) -> Set<String>? {
    guard let archived, let data = Data(base64Encoded: archived),
      let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    else { return nil }
    do {
      var inserted = Set<String>()
      for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
        if let details = try? change.changeDetails(for: .asset) {
          inserted.formUnion(details.insertedLocalIdentifiers)
        }
      }
      return inserted
    } catch {
      log("change history unavailable, using creation dates: \(error)")
      return nil
    }
  }

  /// The same resource the app hashes (PHAssetExtensions.getResource), plus a live photo's video.
  private static func uploadResources(_ asset: PHAsset) -> [PHAssetResource] {
    let all = PHAssetResource.assetResources(for: asset)
    let types: [PHAssetResourceType] =
      asset.mediaType == .image ? [.photo, .alternatePhoto, .fullSizePhoto] : [.video, .fullSizeVideo, .fullSizePairedVideo]
    let media = all.filter { types.contains($0.type) }
    let fullSize: PHAssetResourceType = asset.mediaType == .image ? .fullSizePhoto : .fullSizeVideo
    let main =
      media.count == 1
      ? media.first
      : media.first { $0.value(forKey: "isCurrent") as? Bool ?? false } ?? media.first { $0.type == fullSize }
    guard let main else { return [] }
    guard asset.mediaSubtypes.contains(.photoLive),
      let video = all.first(where: { $0.type == .fullSizePairedVideo }) ?? all.first(where: { $0.type == .pairedVideo })
    else { return [main] }
    return [main, video]
  }

  private static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func destination(
    _ server: String, _ token: String, _ headers: [String: String], _ deviceId: String,
    _ asset: PHAsset, _ resource: PHAssetResource, hidden: Bool
  ) -> URLRequest? {
    let created = asset.creationDate ?? Date()
    var components = URLComponents(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/assets/raw")
    components?.queryItems = [
      URLQueryItem(name: "sessionKey", value: token),
      URLQueryItem(name: "deviceAssetId", value: asset.localIdentifier),
      URLQueryItem(name: "deviceId", value: deviceId),
      URLQueryItem(name: "filename", value: resource.originalFilename),
      URLQueryItem(name: "fileCreatedAt", value: iso.string(from: created)),
      URLQueryItem(name: "fileModifiedAt", value: iso.string(from: asset.modificationDate ?? created)),
      URLQueryItem(name: "isFavorite", value: asset.isFavorite ? "true" : "false"),
    ] + (hidden ? [URLQueryItem(name: "visibility", value: "hidden")] : [])
    // URLComponents leaves "+" alone, which a form decoder reads as a space.
    let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    components?.percentEncodedQuery = query
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  /// Asks the server which of `ids` it already has (by checksum). Empty on any failure: then they are uploaded and
  /// the server answers "duplicate", as before.
  private static func alreadyOnServer(
    _ ids: [String], checksums: [String: String], server: String, token: String, headers: [String: String]
  ) -> Set<String> {
    guard let body = UploadPlan.checkBody(ids, checksums: checksums),
      var components = URLComponents(
        string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/assets/bulk-upload-check")
    else { return [] }
    components.queryItems = [URLQueryItem(name: "sessionKey", value: token)]
    guard let url = components.url else { return [] }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let done = DispatchSemaphore(value: 0)
    var found = Set<String>()
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
        found = UploadPlan.duplicates(fromCheckResponse: data)
      } else {
        log("server check failed: \((response as? HTTPURLResponse)?.statusCode ?? 0) \(error.map { "\($0)" } ?? "")")
      }
      done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 20)
    return found
  }

  private static func customHeaders(_ defaults: UserDefaults) -> [String: String] {
    guard let json = defaults.string(forKey: "widget_custom_headers")?.data(using: .utf8) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: json)) ?? [:]
  }

  /// Unified log plus `upload-extension.log` in the app group (read it with devicectl).
  static func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
    let file = dir.appendingPathComponent("upload-extension.log")
    let line = Data("\(iso.string(from: Date())) \(message)\n".utf8)
    if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
      try? FileManager.default.removeItem(at: file) // ponytail: drop the old log at 1 MB
    }
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: file)
    }
  }
}
