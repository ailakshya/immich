import Foundation

/// The upload extension's decisions, free of PhotoKit so `ios/scripts/upload_plan_check.sh` can test them on a Mac.
enum UploadPlan {
  /// The asset a job uploads, read from its destination (`deviceAssetId`): on iOS 26 a finished job's
  /// `resource.assetLocalIdentifier` comes back empty.
  static func assetId(destination: URL?) -> String? {
    guard let destination, let items = URLComponents(url: destination, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    return items.first { $0.name == "deviceAssetId" }?.value.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// One-time repair of state written before `assetId(destination:)`: every acknowledged job was a success but
  /// was never removed from `inflight`, so those ids are done.
  static func migrateInflight(done: inout Set<String>, inflight: inout [String]) {
    done.formUnion(inflight)
    done.remove("")
    inflight = []
  }

  /// Walks `queue` in chunks of `chunk`, asking `check` which ids the server already has, until `want` ids are
  /// left to upload or `limit` ids were checked. Ids after the checked part are not returned (next call).
  static func pickNotOnServer(
    _ queue: [String], want: Int, chunk: Int = 200, limit: Int = 1000, check: ([String]) -> Set<String>
  ) -> (picked: [String], onServer: Set<String>) {
    var picked: [String] = []
    var onServer = Set<String>()
    var index = 0
    while picked.count < want, index < queue.count, index < limit {
      let part = Array(queue[index..<min(index + chunk, queue.count)])
      index += part.count
      let found = check(part)
      onServer.formUnion(found)
      picked += part.filter { !found.contains($0) }
    }
    return (picked, onServer)
  }

  /// Body for `POST /assets/bulk-upload-check`: the ids that have a checksum, or nil when none has one.
  static func checkBody(_ ids: [String], checksums: [String: String]) -> Data? {
    let assets = ids.compactMap { id in checksums[id].map { ["id": id, "checksum": $0] } }
    return assets.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: ["assets": assets])
  }

  /// Ids the server reported as duplicates in a `bulk-upload-check` response.
  static func duplicates(fromCheckResponse data: Data) -> Set<String> {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = json["results"] as? [[String: Any]]
    else { return [] }
    return Set(results.compactMap { $0["reason"] as? String == "duplicate" ? $0["id"] as? String : nil })
  }

  /// In-flight ids whose asset still exists (one entry per job, order kept).
  static func prune(_ inflight: [String], existing: Set<String>) -> [String] {
    inflight.filter { existing.contains($0) }
  }

  /// What to register next: assets added to the library since the app last ran first, then the app's candidate
  /// list, each once, leaving out what is done, failed or already in flight.
  static func queue(added: [String], candidates: [String], skip: Set<String>) -> [String] {
    var seen = skip
    return (added + candidates).filter { seen.insert($0).inserted }
  }

  /// Applies the outcomes of acknowledged jobs. `inflight` holds one id per registered job (a live photo has two).
  static func settle(
    _ outcomes: [(id: String, ok: Bool)], done: inout Set<String>, failed: inout Set<String>, inflight: inout [String]
  ) {
    for (id, ok) in outcomes {
      if ok {
        done.insert(id)
        failed.remove(id)
      } else if !done.contains(id) {
        failed.insert(id)
      }
      if let i = inflight.firstIndex(of: id) { inflight.remove(at: i) }
    }
  }

  /// Registers as many of `count` jobs as fit. Photos applies a change block all or nothing, so when the queue is
  /// fuller than we think (`isLimit`), try half; any other error stops. Returns how many were registered (a prefix).
  static func register(_ count: Int, attempt: (Int) throws -> Void, isLimit: (Error) -> Bool, log: (String) -> Void) -> Int {
    var size = count
    while size > 0 {
      do {
        try attempt(size)
        return size
      } catch {
        log("register \(size) jobs failed: \(error)")
        guard isLimit(error) else { return 0 }
        size /= 2
      }
    }
    return 0
  }
}
