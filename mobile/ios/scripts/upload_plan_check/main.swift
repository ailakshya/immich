// Checks UploadPlan (ios/UploadExtension/UploadPlan.swift). Run: ios/scripts/upload_plan_check.sh
import Foundation
struct LimitExceeded: Error {}
struct Broken: Error {}
var failures = 0
func check(_ ok: Bool, _ name: String) {
  print(ok ? "ok   \(name)" : "FAIL \(name)")
  if !ok { failures += 1 }
}

check(UploadPlan.queue(added: ["n1", "c2"], candidates: ["c1", "c2", "c3"], skip: ["c3"]) == ["n1", "c2", "c1"],
      "queue: added first, each once, skipped ids left out")
check(UploadPlan.queue(added: [], candidates: [], skip: []) == [], "queue: empty")

var done: Set<String> = ["old"]
var failed: Set<String> = ["live"]
var inflight = ["a", "live", "live", "b"]
UploadPlan.settle([(id: "a", ok: true), (id: "live", ok: true), (id: "b", ok: false)], done: &done, failed: &failed, inflight: &inflight)
check(done == ["old", "a", "live"], "settle: successes are done")
check(failed == ["b"], "settle: failures are failed, a later success clears one")
check(inflight == ["live"], "settle: one in-flight entry per job removed (live photo keeps its second job)")
UploadPlan.settle([(id: "live", ok: false)], done: &done, failed: &failed, inflight: &inflight)
check(!failed.contains("live") && inflight.isEmpty, "settle: a failed second job of a done asset does not mark it failed")

var sizes: [Int] = []
let fit = UploadPlan.register(200, attempt: { size in sizes.append(size); if size > 64 { throw LimitExceeded() } },
                              isLimit: { $0 is LimitExceeded }, log: { _ in })
check(fit == 50 && sizes == [200, 100, 50], "register: halves on the job limit until a batch fits")
check(UploadPlan.register(10, attempt: { _ in throw Broken() }, isLimit: { $0 is LimitExceeded }, log: { _ in }) == 0,
      "register: stops on other errors")
check(UploadPlan.register(10, attempt: { _ in throw LimitExceeded() }, isLimit: { $0 is LimitExceeded }, log: { _ in }) == 0,
      "register: full queue registers nothing")
check(UploadPlan.register(0, attempt: { _ in }, isLimit: { _ in true }, log: { _ in }) == 0, "register: nothing to do")

check(UploadPlan.assetId(destination: URL(string: "https://h/api/assets/raw?sessionKey=k&deviceAssetId=7E60-AB%2FL0%2F001&deviceId=d"))
      == "7E60-AB/L0/001", "assetId: read from the destination query")
check(UploadPlan.assetId(destination: URL(string: "https://h/api/assets/raw?deviceAssetId=")) == nil, "assetId: empty is nil")
check(UploadPlan.assetId(destination: nil) == nil, "assetId: no destination")
var migratedDone: Set<String> = ["", "x"]
var staleInflight = ["a", "b", "a"]
UploadPlan.migrateInflight(done: &migratedDone, inflight: &staleInflight)
check(migratedDone == ["x", "a", "b"] && staleInflight.isEmpty, "migrate: stale in-flight ids become done, empty id dropped")

var asked: [[String]] = []
let pick = UploadPlan.pickNotOnServer(["a", "b", "c", "d", "e"], want: 2, chunk: 2, limit: 10) { part in
  asked.append(part)
  return Set(part.filter { $0 == "a" || $0 == "b" || $0 == "c" })
}
check(pick.picked == ["d", "e"] && pick.onServer == ["a", "b", "c"] && asked == [["a", "b"], ["c", "d"], ["e"]],
      "pick: checks chunk by chunk until enough are left to upload")
let capped = UploadPlan.pickNotOnServer(Array(repeating: "x", count: 50).enumerated().map { "\($0.offset)" }, want: 99,
                                        chunk: 10, limit: 20) { Set($0) }
check(capped.picked.isEmpty && capped.onServer.count == 20, "pick: stops after the check limit")
check(UploadPlan.pickNotOnServer(["a", "b"], want: 1, check: { _ in [] }).picked == ["a", "b"],
      "pick: a failed check (nothing found) uploads as before")

let body = UploadPlan.checkBody(["a", "b"], checksums: ["a": "c2hh"]).flatMap { try? JSONSerialization.jsonObject(with: $0) }
check((body as? [String: [[String: String]]])?["assets"] == [["id": "a", "checksum": "c2hh"]], "checkBody: only ids with a checksum")
check(UploadPlan.checkBody(["b"], checksums: [:]) == nil, "checkBody: none has a checksum")
let response = Data(#"{"results":[{"id":"a","action":"reject","reason":"duplicate","assetId":"x","isTrashed":false},{"id":"b","action":"accept"},{"id":"c","action":"reject","reason":"unsupported-format"}]}"#.utf8)
check(UploadPlan.duplicates(fromCheckResponse: response) == ["a"], "duplicates: only reject/duplicate")
check(UploadPlan.duplicates(fromCheckResponse: Data("oops".utf8)).isEmpty, "duplicates: bad response is empty")

check(UploadPlan.prune(["live", "gone", "live", "b"], existing: ["live", "b"]) == ["live", "live", "b"],
      "prune: drops jobs of deleted photos, keeps both jobs of a live photo")
check(UploadPlan.queue(added: ["p1", "p2"], candidates: ["p3", "p1"], skip: []) == ["p1", "p2", "p3"],
      "pending: earlier finds are kept ahead of new ones, each once")

if failures > 0 { fatalError("\(failures) checks failed") }
print("all UploadPlan checks passed")
