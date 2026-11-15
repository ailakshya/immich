# iOS background upload

How the mobile app keeps backing up on iOS after the user locks the phone, how progress reaches the lock screen, and where the limits are.

:::note Status
The lock-screen handoff, Live Activity and speed/ETA described here are experimental. The scheduler livelock fix and the queue-before-files cancel order are independent bug fixes.
:::

## Two uploaders

| | Foreground uploader | Background uploader |
| --- | --- | --- |
| Runs when | The app is open | The app is suspended (phone locked / app switched away) |
| Who transfers the bytes | The app (`ForegroundUploadService`, `cupertino_http`) | iOS itself (`nsurlsessiond`) through a background `URLSession` (`BackgroundUploadService`, `background_downloader`) |
| Speed | Full speed | iOS decides (see [Discretionary scheduling](#discretionary-scheduling)) |
| Per-file progress in the app | Live | Only while the app is awake |

They share the app's temporary directory: the foreground uploader normally clears it when it starts, and queued background tasks read their files from it.

When the foreground uploader starts on iOS (`BackupNotifier.startForegroundBackup`):

- If the background session still holds tasks, they keep running. The foreground run skips their assets (`uploadCandidates(skipAssetIds: …)`) and does not clear the temp directory, so both uploaders run side by side on different files.
- If the queue is empty, or holds tasks this process did not create in the foreground (handoff or refill leftovers, which are discretionary), it is cancelled (`BackgroundUploadService.cancel()`, which also cleans up leftover temp files). A fresh batch of 100 (`_foregroundBatchSize`) is then queued in the background session while the app is in the foreground. To keep about 1 GB of file exports off the app-start path, it runs 20 s later (`prequeueDelay`), takes the batch from the end of the candidate list (`fromEnd`) while the foreground run works from the front, and does not clear the temp directory (`clearCache: false`). Later foreground restarts skip the queued assets. A queue the app created in the foreground (tracked in `_foregroundQueued`) is kept, so a quick Face ID glance loses nothing. See [Discretionary scheduling](#discretionary-scheduling).

## Lifecycle

```
App open ──────────────► foreground uploader (live progress, full speed)
   │ lock / switch away
   ▼
AppLifeCycleNotifier._performPause
   1. BackupNotifier.continueInBackground(userId)   ← registered first, so the activity never shows "paused"
   2. BackupNotifier.stopForegroundBackup()
   │
   ▼
continueInBackground
   • asks iOS for ~30 s of background time   (channel immich/background_time → beginBackgroundTask)
   • waits for any in-flight cancel of the background queue
   • startBackupWithURLSession → uploadBackupCandidates: export 100 candidates to temp files, enqueue them
   • ends the background time
   │
   ▼
App suspended. iOS uploads the files.
   │ files finish
   ▼
iOS wakes the app for a few seconds (TaskStatusUpdate via taskStatusStream)
   • BackupNotifier._onBackgroundTaskStatus: refresh counts, record bytes, update the Live Activity
   • queue drained → enqueue the next 100
   │ user opens the app
   ▼
startForegroundBackup keeps any still-queued background tasks running; the foreground uploader takes the rest
```

### Why the app asks for background time from Dart

The app uses the scene lifecycle (`FlutterSceneDelegate` in `Info.plist`), so `UIApplicationDelegate.applicationDidEnterBackground` is never called. Without explicit background time iOS suspends the app about 2 seconds after lock, before the 100 files are exported and enqueued. `continueInBackground` therefore calls `immich/background_time` `begin` / `end` around the handoff (`ios/Runner/Core/BackupLiveActivity.swift`, `BackgroundTime`).

### No holding queue on iOS

`background_downloader`'s holding queue limits how many tasks are handed to the OS at once. Immich configures it as `(6, 6, 3)`: at most 3 running tasks per group. Held tasks live in the app's memory, and a suspended app cannot release them.

With the holding queue on, a locked phone uploads only the first 3 files of a batch. The next 3 are released only when iOS happens to wake the app, which showed up as 2–3-file bursts followed by minutes of nothing.

On iOS the holding queue is disabled (`Config.never` in `main.dart` and `BackgroundWorkerBgService`). Every task goes straight to `NSURLSession`, which queues and throttles the transfers itself. Android keeps `(6, 6, 3)`.

### Batches

`uploadBackupCandidates(batchSize:)` enqueues one batch:

- 100 by default (the scheduled background worker).
- Up to 300 files / 3 GB (or half the free space) for the batch queued while in the foreground (`_foregroundBatchSize`, `_foregroundBatchBytes`).
  - Exports are spaced by 250 ms (`_foregroundExportPause`). A 500-file / 5 GB budget exported back to back starved the app: endless spinner, `Device sync` at 16 s instead of 0.3 s.
  - Each enqueued chunk is recorded as foreground-created while the app is still in the foreground (`onEnqueued`), so a lock part-way through does not get those chunks replaced on the next open.
- 50 for the lock-time handoff and for refills while suspended (`_lockedBatchSize`)

iOS does not wake a suspended app per finished task. It delivers the session's events once the whole queue has drained (`handleEventsForBackgroundURLSession`). Each wake-up is therefore the only point where the app can:

- refresh the Live Activity
- queue the next batch once 5 or fewer uploads remain (`_refillThreshold`). The new batch skips the still-queued assets (`skipAssetIds`) and keeps the temp directory while any remain. It is taken from `_nextCandidates`, about 300 candidates prepared in the foreground after the pre-queue, so the short wake needs no candidate query. The refill runs before the progress counts, which are throttled to one query per 5 s while in the background.

A smaller batch means more frequent updates. A larger batch means fewer refills queued from the background, which are discretionary.

## Discretionary scheduling

Apple: *"For transfers started while your app is in the background, the system always considers `isDiscretionary` to be true."* Discretionary transfers start when the system finds conditions suitable, which can be hours later.

Observed on device (charging, Wi-Fi):

1. 50 tasks were created by the lock-time handoff.
2. 40 finished within a minute.
3. The other 10, mostly small PNGs, stayed `running` at 0–2 % while the NAS sat idle.

Because the session never drained, iOS never woke the app, and no refill was queued.

Transfers created in the foreground are not discretionary, so the app keeps a batch queued in the background session while it is open (see [Two uploaders](#two-uploaders)). After a lock, that batch runs promptly. The lock-time handoff and refills still create discretionary tasks; they remain as a fallback.

## Progress on the lock screen

A Live Activity (`ios/WidgetExtension/widgets/BackupLiveActivity.swift`) is driven from Dart over the `immich/backup_live_activity` channel. It needs `NSSupportsLiveActivities` in `Info.plist` and no push entitlement, because the app updates it locally.

`BackupActivityAttributes.ContentState` is declared in both the Runner and the widget extension. ActivityKit matches the type by name and Codable shape, so the two copies must stay identical.

| Field | Source |
| --- | --- |
| `done` / `total` | `BackupState.backupCount` / `totalCount` |
| `paused` | Neither uploader is running |
| `detail` | `"12.3 MB/s · ~1h 5m left"` (see below) |
| `file`, `fileProgress` | Foreground only: the in-flight file and its progress. Hidden while locked, because it could only change once per drained batch. |
| `updatedAt` | Set natively on every push and shown as "Updated 3 min ago" (`Text(date, style: .relative)`). The system keeps it ticking while the app is suspended, so stale numbers read as stale. |

The activity is updated whenever the counts change, and at most once per second for file progress.

### Why there is no live per-file bar while locked

iOS tracks `countOfBytesSent` for every background task, but a suspended app gets no progress callbacks and cannot update its Live Activity. The app only runs during the short wake-ups after tasks finish. A live bar while suspended would need push updates from the server (APNs Live Activity push), which requires a paid developer account and server-side support.

A switch in backup settings, **Progress on Lock Screen** (iOS only), turns the activity off. The choice is stored natively (`backup_live_activity_disabled` in `UserDefaults.standard`). Turning it off ends any running activity, and later updates are ignored. iOS also has its own per-app switch under Settings › Immich › Live Activities.

## Speed and time left

- **Bytes sent.**
  - Foreground: deltas of the per-file upload progress callback (`_handleForegroundBackupProgress`).
  - Background: the size of each finished file, looked up at wake-up.
- **Speed.**
  - Bytes over the last 30 seconds (`rawBytesPerSecond`, at least 2 samples 3 s apart).
  - Smoothed with an exponential moving average (0.3 new, 0.7 previous).
  - Redrawn at most every 2 seconds. The last value is kept during short gaps instead of blanking.
- **Bytes left.**
  - Average original size of up to 200 remaining candidates, sampled evenly over the candidate list (`sampleEvenly`) and summed natively from PhotoKit (`immich/asset_sizes`, `PHAssetResource` `fileSize` for photo, video and paired video).
  - Multiplied by the current `remainderCount`, so it shrinks as uploads finish.
  - The first sample waits 2 minutes after backup starts and never runs while the app is in the background: there it took 111 s and starved a refill. Its candidate query took 10–13 s on a large library and competes with the timeline for the single database connection during app start.
  - Re-sampled at most every 10 minutes. Measuring every candidate (thousands of PhotoKit lookups) took long enough for iOS to suspend the app before any estimate existed.
- **Time left.**
  - Bytes left ÷ speed.
  - Rounded to minutes under an hour and to 5-minute steps above (`formatSpeedDetail`).

The same text is shown in the app's Backup page ("Upload speed" card). A "Now uploading" card shows the current foreground file and opens the Upload details page.

## Photos background-upload extension (iOS 26.1+)

The URLSession path can only upload what the app queued before iOS suspended it, so each lock uploads one batch. iOS 26.1 added an extension point for backup apps, `com.apple.photos.background-upload`. Photos runs the extension on its own schedule, also while the app is suspended or not running, and uploads the files the extension registers as jobs.

- **Target:** `ios/UploadExtension` (ExtensionKit, deployment target 26.1, embedded in `Extensions/`). `UploadExtension.swift` implements `PHBackgroundResourceUploadExtension.process()`.
- **Each call:**
  1. Retries each failed job once (`PHAssetResourceUploadJob.fetchJobs(action: .retry)`).
  2. Acknowledges the finished jobs to free their slots (`jobLimit` counts unacknowledged jobs).
  3. Registers new jobs up to the limit. Photos created since the app last configured the extension come first, then the app's candidate list.
  4. Returns `.processing` only while assets are left over for lack of free job slots, otherwise `.completed`, even with jobs in flight. With `.processing`, Photos calls again only after every queued job finishes, so a job that never finishes (its photo was deleted) stopped all new photos. After `.completed`, Photos called the extension again by itself when a photo was added (00:25 → 00:50 on 2026-11-16).
- **New photos without the app:** the extension keeps its own bookmark in Photos' change history (`upload_extension_change_token`; it starts at the app's and advances every run). It also keeps a list of photos it found but could not register yet (`upload_extension_pending`). So photos taken, saved or imported while the app is closed are picked up whatever their creation date. In-flight jobs whose photo no longer exists are dropped (`UploadPlan.prune`).
- **What to upload:** the app writes `upload-extension.json` to the app group (`UploadExtensionConfig.swift`, channel `immich/upload_extension`). It holds the device id, the candidate ids, the selected and excluded album ids, `since`, and `changeToken`, the Photos change-history position (`currentChangeToken`, archived). Assets added after that position are uploaded too, whatever their creation date, so imported or saved photos are covered. If the history is missing or expired, the extension falls back to `creationDate > since`. This happens in the foreground, at most every 10 min and 30 s after a resume, because the candidate query is slow on large libraries. Login comes from the widget keys (`widget_server_url`, `widget_auth_token`, `widget_custom_headers`).
- **Already on the server:** the app's list is a snapshot, so assets it uploaded itself afterwards were sent again and reported as duplicates (74 of the last 86 on 2026-11-16). The app now sends each candidate's checksum too. Before registering, the extension asks `POST /assets/bulk-upload-check` in chunks of 200 (at most 1000 per call) and marks the server's duplicates as done. If the check fails, nothing is skipped, and the server rejects the duplicates as before.
- **Resource:** the same one the app hashes (`PHAsset.getResource()`: the current version of an edited photo), so the checksum matches the local hash. A live photo also uploads its paired video as `visibility=hidden`; the server pairs the two by content identifier.
- **Foreground:** `startForegroundBackup` sets `upload_extension_paused`, so the foreground uploader and the extension don't upload the same files. `continueInBackground` clears it. Both paths run at a lock. The URLSession batch (50) starts within seconds, because the app creates it while it still has background time. The extension, which iOS runs much later and at low priority, takes the rest and any new photos. After queuing, the app writes the URLSession queue's asset ids to `upload_extension_queued` (channel `setQueued`), and the extension leaves them out.
- **Server:** a job's body is the bare file, and `POST /assets` only accepts multipart. Jobs therefore go to `<server>/api/assets/raw`, with the upload fields and `sessionKey` in the query string. A converter in front of the server streams the body to `POST /api/assets` as multipart. It is a stdlib Python script, reached through a reverse-proxy location for `/api/assets/raw`. With Nginx Proxy Manager, an exact-match `location = /api/assets/raw` in `/data/nginx/custom/server_proxy.conf` works. Every proxy host includes that file, so guard it with a `$host` check. Upstream would need a raw-body upload endpoint on the server instead.
- **Tests:** the extension's decisions (queue order, settling acknowledged jobs, halving on the job limit) live in `UploadPlan.swift`, which doesn't depend on PhotoKit. `ios/scripts/upload_plan_check.sh` compiles and runs its checks on a Mac. The album query is covered in `test/medium/repositories/backup_repository_test.dart`.
- **State:** done, failed and in-flight asset ids are kept in the app-group defaults. The failed set is cleared whenever the app writes a new list, so a server outage or a missing proxy route does not skip those assets for good. In-flight ids are kept, because those jobs are still queued in Photos. Each call logs one line to `upload-extension.log` in the app-group container and to the unified log (subsystem `immich`, category `UploadExtension`).
- **`BackgroundUploadURLBase`:** the extension's Info.plist must name the upload server's base URL, or `setUploadJobExtensionEnabled(true)` fails with `PHPhotosErrorDomain Code=-1`. It comes from `IMMICH_UPLOAD_URL_BASE` in `Signing.local.xcconfig`. Because the URL is fixed at build time, an App Store build can't serve self-hosted servers this way. Upstream has to solve this before shipping (for example with a relay at a fixed URL).
- **Preflight:** before uploading, iOS sends `OPTIONS` to the destination to check for resumable uploads (draft RUFH). Answering `501` means "not supported", and the converter does that by default.
- **Platform notes from Apple's article ("Uploading asset resources in the background"):**
  - The extension is unavailable in Simulator.
  - iOS 27 renames the protocol to `PHBackgroundResourceUploadJobExtension` (`processJobs`, `willTerminate`), and the iOS 26.1 protocol is deprecated.
  - A developer-forum report says `process()` is never scheduled while iCloud Photos is on, even though enabling succeeds.
- **Signing:** the extension needs its own bundle id (`<prod id>.UploadExtension`) and a provisioning profile with the app group. Xcode creates it only while an Apple ID is signed in under Settings › Accounts.

## Known limits

- Swiping the app away in the app switcher cancels all background transfers. This is iOS behaviour.
- Wi-Fi-only settings (`useCellularForPhotos` / `useCellularForVideos`) are applied as `requiresWiFi` on each background task, so iOS holds those tasks until Wi-Fi is available.
- Android does not use this path. Its background upload runs the regular uploader inside a background worker, with the existing "only while charging" and delay settings.

## Related fixes

- **Scheduler livelock** (`lib/wm_executor.dart`). With dynamic spawning, a task queued while the only idle worker was still initializing made `_ensureWorkersInitialized` and `_schedule` call each other forever on microtasks, freezing the main isolate. iOS killed the app with watchdog code `0x8BADF00D`. Regression test: `test/unit/utils/isolate_worker_test.dart`.
- **Cancel order** (`BackgroundUploadService.cancel`). The queue is now reset before temporary files are deleted. A queued task pointing at a deleted file made `NSURLSession uploadTask(with:fromFile:)` throw and abort the app.

## Debugging on a device

```bash
# list and copy crash reports
xcrun devicectl device info files --device <id> --domain-type systemCrashLogs
xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs --source <file>.ips --destination .

# copy the app's log database (development-signed builds only)
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier <bundle id> --source Documents/immich_logs.sqlite --destination .
sqlite3 immich_logs.sqlite "select created_at, logger, message from logger_messages order by id desc limit 50"

# symbolicate Dart frames (the App.framework dSYM UUID must match the crash report)
atos -arch arm64 -o build/ios/Release-iphoneos/App.framework.dSYM/Contents/Resources/DWARF/App -l <App load address> <addresses>
```

Useful log lines: `Enqueuing 100 background upload tasks` (handoff done), `Found N pending tasks` / `Resuming upload` (existing queue reused), `Foreground backup cancelled` (pause or restart).

## Building for a physical iPhone

The simulator cannot exercise any of this: Live Activities, background `URLSession` and suspension all need a real device.

1. Install the toolchain pinned in `mobile/mise.toml` (Flutter, Rust with the iOS targets). Use `MISE_EXEC_AUTO_INSTALL=false` to avoid installing the whole repository's toolchain.
2. Generate code. `mise run codegen` runs everything. To run steps individually, use `mise run --skip-deps <task>` for:
   - `//:open-api-dart`
   - `codegen:native`
   - `codegen:dart`
   - `codegen:drift:migration`
   - `codegen:drift:schema`
   - `codegen:pigeon`
   - `i18n:loader`
   - `i18n:keys`

   Missing `codegen:drift:migration` fails the build with `database.steps.dart: No such file`.
3. Create `mobile/ios/Signing.local.xcconfig` with your own `IMMICH_TEAM_ID`, `IMMICH_BUNDLE_ID_PROD`, `IMMICH_BUNDLE_ID_DEV` and `IMMICH_GROUP_ID` (see `Signing.xcconfig`).
4. A free (Personal Team) Apple account cannot sign `aps-environment`, `com.apple.developer.associated-domains` or `com.apple.developer.networking.wifi-info`. Remove them from the local `*.entitlements` files and never commit that change. Free builds also expire after 7 days.
5. If Swift Package resolution fails with `Disabled default traits on package 'swift-sharing'`, the pins in `Runner.xcodeproj/.../Package.resolved` and `Runner.xcworkspace/.../Package.resolved` have drifted apart. Flutter resolves through the project and builds through the workspace.
6. Build and install:

   ```bash
   flutter build ios --release
   xcrun devicectl device install app --device <id> build/ios/iphoneos/Immich.app
   ```

   The bundle is `Immich.app`, not `Runner.app`. Use a release build, because debug builds stop launching once the device is disconnected from the Mac.

## How to verify background upload

Do not trust the lock-screen bar alone: a suspended app updates it only at wake-ups. Match the device's own log against what the server received.

1. Copy `Documents/immich_logs.sqlite` from the device (see [Debugging on a device](#debugging-on-a-device)) and list the lifecycle events: `App paused`, `App resumed`, `Enqueuing N background upload tasks`, `Found N pending tasks`.
2. On the server, list assets created in the same window with their sizes:

   ```sql
   SELECT "createdAt", e."fileSizeInByte"
   FROM asset a
   LEFT JOIN asset_exif e ON e."assetId" = a.id
   WHERE a."ownerId" = '<user id>' AND a."createdAt" > now() - interval '30 minutes'
   ORDER BY 1;
   ```

3. Files whose `createdAt` falls between a `paused` and the next `resumed` were uploaded while locked.
4. To check whether anything is in flight right now, sample the NAS interface counters, for example `rx_bytes` twice, 15 s apart.

Lock the phone for at least 5–10 minutes. Shorter tests mostly measure the handoff, and every unlock cancels the background queue.

## Investigation log

Each row is a symptom seen on a device, the evidence that explained it, and the change that came out of it. Keep this table up to date with every change in this area.

| Symptom | Evidence | Cause | Change |
| --- | --- | --- | --- |
| App killed a few seconds into a background run | Crash report `0x8BADF00D` (scene-update watchdog); symbolicated Dart stack `_awaitNotFuture → _ensureWorkersInitialized → _schedule` | Microtask livelock in `wm_executor.dart` while a worker is still initializing | Return early when no worker can be spawned; regression test |
| Albums tab empty until pull-to-refresh | The album query on a copy of the device database returned all albums in 0.27 s | The list loaded once; later, a value-equal refresh did not trigger the selector's listener | `watchChanges()` on album tables; the selector sorts already-loaded albums on open |
| Uploads stop as soon as the phone is locked | Log shows the pause, then nothing until the next resume | The foreground uploader is stopped on pause by design | Hand off to the background `URLSession` on pause |
| Handoff starts but never enqueues | `Found N backup candidates` logged, `Enqueuing` missing | Scene lifecycle: `applicationDidEnterBackground` never fires, so no background time was granted | Request background time from Dart (`immich/background_time`) |
| Two uploads fail after a quick lock/unlock | `PathNotFoundException` for temp files | The handoff and the restarted foreground uploader raced on the shared temp directory | Abort the handoff if the foreground run restarted |
| App aborts in `__NSURLBackgroundSession _uploadTaskWithTaskForClass` | Crash report's last exception backtrace; log shows a resume of the queue 3 s after an unlock began cancelling it | Cancel deleted temp files before resetting the queue, so queued tasks pointed at missing files | Reset the queue before deleting files; the handoff waits for an in-flight cancel |
| Lock screen shows "paused" while uploads continue | Server receiving files during the "paused" period | The foreground stop was published before the handoff registered | Register the handoff before stopping the foreground run |
| Per-file bar freezes on lock | — | No per-file progress while suspended | Show the last file the background session finished |
| Speed and time left flicker | — | Recomputed on every progress tick and blanked during gaps | 30 s window, moving average, at most one redraw per 2 s, keep the last value, rounded ETA |
| Locked phone uploads 2–3 files, then stalls for minutes | Enqueued 100; the server got 2–3; NAS receive rate near 0 afterwards | Holding queue `(6, 6, 3)` keeps tasks in app memory, and a suspended app cannot release them | Holding queue disabled on iOS |
| Queued uploads thrown away within seconds | Log shows paused and resumed every few seconds (Face ID unlocking into the app); 100 queued tasks dropped to 12 within 4 s | `startForegroundBackup` cancelled the background queue on every resume, because the foreground run clears the shared temp directory | Keep queued tasks, skip their assets in the foreground run, and skip the temp-directory clear while tasks remain; regression test |
| Lock screen shows speed but no time left | No size-lookup failure logged; lookup covered about 5,000 assets | An exact PhotoKit size lookup for every candidate did not finish before suspension | Sample 200 evenly spread candidates, average × remaining count |
| Lock screen shows `<uuid>_o_IMG_9549.PNG` | — | `task.filename` is the exported temp copy | Use the upload's `filename` form field |
| Locked file row stuck on one file for many minutes | Server received files every minute while the row did not change | A suspended app is only woken once the whole batch has drained | Batches of 50 while locked, "Updated … ago" label, file row only in the foreground |
| Batch never finishes while locked; no refill | Background task records: 40 complete, 10 `running` at 0–2 % for minutes; NAS idle; no wake-up | Handoff tasks are created in the background, so iOS parks them as discretionary | Keep a batch of 50 queued in the background session while the app is in the foreground |
| No foreground batch after reopening | `Keeping 5 background uploads running`: 5 stragglers from an earlier lock-time batch were kept, so no fresh batch was created | "Keep the queue" did not distinguish discretionary leftovers | Keep only queues created in the foreground; replace leftovers with a fresh batch of 100 |
| App slow to load after the foreground pre-queue | App alive and logging (no crash); 100 file exports ran before the foreground upload, during app start | Pre-queue on the app-start critical path, competing with timeline, hashing and sync | Pre-queue 20 s later, from the end of the candidate list, without clearing the temp directory |
| No next batch after a locked batch finished | All 50 uploads answered `201` on the server; 15 task records were written at the wake-up (15:31), but the last one (`t2.mov`) was still `running` and the app logged nothing | Refill required an empty queue, and the last completion arrived after the wake had already checked it | Refill at ≤ 5 remaining, skip still-queued assets, keep the temp directory, log and flush each wake |
| Abort in `_uploadTaskWithTaskForClass` after rotating the phone | Crash report via `BDPlugin.methodEnqueueAll`; log shows a pause at the rotation (15:38:45), and the crash 6 s later | A long pre-queue was still exporting while the pause handoff started another batch: that batch cleared the temp directory and reset the abort flag, and the first then enqueued deleted files | `uploadBackupCandidates` runs one batch at a time; `cancel()` waits for an in-flight batch; tasks whose file is gone are dropped before enqueueing; regression tests |
| App stuck after reopening: no sync, no backup | Last backup log `Replacing 5 background uploads…` (start of `cancel()`); every later resume waited on the first and logged nothing | `cancel()` never returned (step unknown; `BaseDownloader … after retry timeout` logged meanwhile), and the resume path awaits it | Queue preparation and the handoff's wait on a cancel time out after 20 s; `cancel()` logs each step's duration to identify the hang |
| Endless spinner on open | App alive and logging; the pre-queue had just exported 498 files (~5 GB); device sync took 16 s and the size sample 26 s | Pre-queue export saturated disk I/O and the database. A second Immich process seen at the time was the App Store build, which has its own container, so it was not involved | Foreground batch capped at 100 files / 1 GB, first size sample after 2 minutes |
| Refill fires but never enqueues | `Background wake: 0 uploads still queued, queueing the next batch` at 15:57:36, then nothing; no new tasks; NAS idle; the size sample logged `sampled in 111013 ms` at 15:57:33 | The 2-minute size sample ran in the background and held the database while the refill's candidate query waited, and the wake's background time ran out | Size sample only in the foreground; refill uses candidates prepared in the foreground; counts after the refill, throttled |
| No foreground batch even after ~30 s in the app | No `Pre-queued` line; `restarting the backup` every ~10 s | `stopForegroundBackup` cancelled the 20 s pre-queue timer, and the foreground run restarts after each hash or sync | Restarts leave the timer running; it checks for a real pause when it fires |
| "Crash" leaving the backup album selection page | No iOS crash report; `Bad state: No element` in `NavigatorState.pop` from `backup_album_selection.page.dart:145` | The back handler awaits database queries; a second back gesture popped twice (upstream bug, exposed by a slow database) | Ignore back gestures while one is handled |
| Refill ran up to 7 times at once | Several `Background wake … queueing the next batch` lines in the same millisecond | `_bgEnqueuing` was set after the first await, so completions delivered together all passed the check | Take the flag before any await |
| Refilled batches stall after a few minutes | Two refills while locked (16:16:30, 16:19:22); 155 files / 2.1 GB in 8 min; then 41 running and 6 enqueued with the NAS idle | Refills are created during a background wake and are discretionary | Larger, paced foreground batch (300 files / 3 GB); overnight test pending to measure iOS's pace for parked transfers |
| "Sync failed. Cannot process backup." after reopening | `Request aborted by abortTrigger` on `/api/sync/stream` when the app went to the background; later syncs completed | An aborted request returns an unsuccessful result instead of `CanceledError`, so `onRemoteSyncComplete(false)` set `BackupError.syncFailed` | Do not report a sync failure that ends while the app is backgrounded (`appStateProvider` paused, hidden or detached) |
| A lock uploads almost nothing | `Found 2 pending tasks` → `Resuming upload 2 assets`, nothing added; handoff took 29.7 s | `startBackupWithURLSession` only resumes when any task is queued; with refills off, a lock with a few leftovers queued nothing new. The counts query ran first and used most of the background time | The handoff resumes the queue and adds a batch when fewer than 10 remain (skipping queued assets, keeping their temp files); counts are refreshed afterwards |
| A lock uploads only one batch | With refills off, every lock uploaded at most one batch (50 files), then stopped until the next lock | The URLSession path can only upload what the app queued before suspension | iOS 26.1+ Photos background-upload extension (`ios/UploadExtension`) plus a raw-body converter on the server; Photos schedules the uploads itself. Converter tested locally (Content-Length and chunked bodies, `+` in filenames); extension type-checks; not yet run on a device |
| Extension "unavailable" | `Upload extension Error Domain=PHPhotosErrorDomain Code=-1 "(null)"` on an iPhone running iOS 26.6 | Info.plist lacked `BackgroundUploadURLBase`, which Apple's article says the system requires for network access validation | Key added from `IMMICH_UPLOAD_URL_BASE` (local xcconfig). Verified: `Upload extension enabled`, and Photos called `process()` within a minute of the lock |
| Extension stuck at "0 free slots" | First run registered 200 jobs (they failed: proxy route missing), retried them, acknowledged 200, but still counted 200 in flight | The job's asset id was read after acknowledging, when PhotoKit has already deleted the record, so nothing matched | Read each outcome before acknowledging; always probe at least 10 slots; on `limitExceeded` retry the change block with half the jobs (it is all-or-nothing). Clearing in-flight ids on every new list was tried and dropped: it made the next run request a full 200 against a queue still holding 136 |
| First extension batch: 50 duplicates | At 23:00:04 a fresh launch queued a URLSession batch of 50; 2 s later the extension got a list with the same assets; the server answered `duplicate` for exactly 50 uploads, then stored new ones (14 in the first 3 min, up to 102 MB videos) | The handoff trusted `_uploadExtensionActive`, which is false until the first configure after a launch; the list did not leave out queued assets | The handoff asks iOS (`isEnabled`); the extension list leaves out assets still in the URLSession queue |
| Extension added only 10 per call | `acknowledged 200 (200 ok) … 200 in flight`, then `registered 10 of 10`; the app-group state held 220 in-flight ids and a done set of `[""]` | On iOS 26 a finished job's `resource.assetLocalIdentifier` is empty, so no acknowledged job matched an in-flight id. Photos *did* call the extension again after each batch (17:55, 18:07, 18:17 UTC), which settled that open question | Read the asset id from the job's destination (`deviceAssetId` query item). One-time migration (`upload_extension_state_version` 2) moves the stale in-flight ids to done; they were all acknowledged as successful |
| Duplicates from a stale list | Overnight: 706 uploads, 281 of them duplicates; for the final batch, 74 of 86. Converter counts matched the registered jobs exactly (200 and 86), so Photos did not re-send files | The candidate list was built at 23:12, and the old URLSession path and the foreground uploader sent many of those assets afterwards | Checksums go into the config; the extension checks `bulk-upload-check` before registering (`UploadPlan.pickNotOnServer`) |
| New photos waiting behind a deleted one | Locked after taking 95 photos: nothing uploaded. The only queued job (00:50) was for an asset no longer in the library; the extension had returned `.processing` | Photos waits for every queued job before calling an extension that returned `.processing`; a deleted photo's job never finishes. New-photo pickup also relied on the app's bookmark | Return `.completed` unless assets are left for lack of slots; the extension owns its change-history bookmark and a pending list; jobs of deleted photos are dropped. Photos still waited on the old job after the update (no call for 30+ min), so the app switches the extension off and on once (`upload_extension_reset_1`) |
| Nothing moves for minutes after a lock | With the extension enabled the handoff skipped the URLSession batch, so a lock uploaded nothing until iOS ran the extension (10–25 min between runs overnight, none for 30 min after the stuck job) | iOS runs the background-upload extension at low priority | Run both: the URLSession batch at the lock for an immediate start, the extension for the rest; the extension skips the app's queued ids |
| Extension never runs again; reset does not help | iOS system log (`log collect`, assetsd, `BackgroundJobService`): at 00:50:07 the "asset resource upload extension runner" pass started (OneDrive's extension failed with 50008 "appex connection was invalidated", then ours registered 1 job and returned `.processing`). From 00:52:22 assetsd logged `Coalescer wants to submit but service has been stuck in Running state for too long` every ~2 min until at least 01:36; at 00:53:10 the background task expired. Switching the extension off and on (01:23) did not clear it | The runner pass stays "Running" while an extension's jobs are outstanding after `.processing`. Its only job was for a deleted photo, so the pass never ended, which also blocks Photos' own background jobs (search indexing, duplicate detection) | Restart the phone (restarts assetsd). The extension now returns `.completed` unless assets are left for lack of slots, so a pass should not wait on stuck jobs; not yet verified |
| Locked uploads pause after 3 minutes | 64 jobs uploaded 23:04–23:07, then nothing for 10+ min: no connections to the converter, NAS idle, extension not called again (Photos calls it once the queued jobs finish) | Unknown; Photos schedules the transfers. Candidates further down the list are older and may be iCloud-only originals, which Photos must download first | Open: watch whether the remaining 136 resume; next steps are smaller batches and videos in their own batches |

Verified on an iPhone 17 Pro (charging, Wi-Fi):

- Locked at 14:21:23, 100 tasks enqueued 8 s later.
- 21 files reached the server in the following 13 s, with transfers continuing at about 4.5–6.5 MB/s.
- The Live Activity showed "Backing up", the speed and the last finished file.

### Open issues

- Reading iOS's own log: connect the phone by cable, then `sudo log collect --device-udid <hardware UDID> --last 1h --output phone.logarchive` (the hardware UDID is from `devicectl device info details`, not the CoreDevice id). Filter on `subsystem == "com.apple.photos.backend" AND category IN {"BackgroundJobService", "BackgroundAssetResourceUpload"}`.


- Upload extension, still unverified:
  - whether Photos keeps the destination request's headers (the token is also sent as `sessionKey` in the query string for this reason)
  - which HTTP method and body encoding a job uses
  - how often Photos calls `process()`
  - whether a free (Personal Team) profile may use the extension point

- After a batch created in the background (discretionary) drains, iOS may delay the wake: no wake was logged 1 minute after the last upload (16:04:45).

- Why `cancel()` hung once after an install that followed a crash, while the old queue had tasks whose files were gone. Step timings are now logged.

- A handoff at 14:41 logged `No pending tasks, starting new upload`, and then the log ended; nothing uploaded afterwards. Log lines are buffered (`LogService`) and lost when iOS suspends the app, so the handoff and refill now flush the log before giving up background time, and log their duration and skip reasons (`Background handoff finished in N ms`, `Background handoff skipped`, `Background queue drained while suspended`).
- Not yet observed: whether the foreground-created batch finishes completely after a lock, and the wake-up and refill that follow.

- `AppLifeCycleNotifier.handleAppResume` can throw `Null check operator used on a null value` (line 60) when two resumes overlap: one resume's `finally` nulls `_resumeOperation` while the other still uses it. The bug predates this work.


- An `objective_c` / `cupertino_http` abort in `RequestBodyStream::cleanup` while a foreground upload is cancelled. It appears to be a package bug that frequent cancels expose.
- Background-created transfers are discretionary. Keeping a batch queued while the app is in the foreground would make them start promptly.
- A sync request at background launch can use an empty server URL (`unsupported URL /server/version`).
- Large libraries (hundreds of thousands of remote assets) make the main timeline bucket query take seconds, and it re-runs on every database change.
