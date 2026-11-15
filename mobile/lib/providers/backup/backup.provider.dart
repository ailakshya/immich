import 'dart:async';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

part 'backup.provider.freezed.dart';

@freezed
abstract class UploadStatus with _$UploadStatus {
  const factory UploadStatus({
    required String taskId,
    required String filename,
    required double progress,
    required int fileSize,
    required String networkSpeedAsString,
    bool? isFailed,
    String? error,
  }) = _UploadStatus;
}

enum BackupError { none, syncFailed }

@freezed
abstract class BackupState with _$BackupState {
  const BackupState._();

  const factory BackupState({
    required int totalCount,
    required int backupCount,
    required int remainderCount,
    required int processingCount,
    required bool isSyncing,
    @Default(BackupError.none) BackupError error,
    required Map<String, UploadStatus> uploadItems,
    @Default({}) Map<String, double> iCloudDownloadProgress,
  }) = _BackupState;

  int get errorCount => uploadItems.values.where((item) => item.isFailed == true).length;
}

final backupProvider = StateNotifierProvider<BackupNotifier, BackupState>((ref) {
  return BackupNotifier(
    ref.watch(foregroundUploadServiceProvider),
    ref.watch(backgroundUploadServiceProvider),
    UploadSpeedManager(),
  );
});

class BackupNotifier extends StateNotifier<BackupState> {
  BackupNotifier(this._foregroundUploadService, this._backgroundUploadService, this._uploadSpeedManager)
    : super(
        const BackupState(
          totalCount: 0,
          backupCount: 0,
          remainderCount: 0,
          processingCount: 0,
          isSyncing: false,
          uploadItems: {},
          error: BackupError.none,
        ),
      );

  final ForegroundUploadService _foregroundUploadService;
  final BackgroundUploadService _backgroundUploadService;
  final UploadSpeedManager _uploadSpeedManager;
  Completer<void>? _cancelToken;

  /// Set while the app is backgrounded and uploads continue through the iOS URLSession.
  String? _bgUserId;
  bool _bgEnqueuing = false;

  /// The foreground uploader's in-flight cancel of the background queue (resets tasks, deletes temp files).
  Future<int>? _bgCancel;
  StreamSubscription<TaskStatusUpdate>? _bgStatusSubscription;

  @override
  void dispose() {
    unawaited(_bgStatusSubscription?.cancel());
    super.dispose();
  }

  /// iOS, app leaving the foreground: queue the remaining candidates on the background URLSession,
  /// which keeps uploading while the phone is locked. Each finished batch queues the next one.
  Future<void> continueInBackground(String userId) async {
    _bgUserId = userId;
    await _uploadExtension.invokeMethod('setPaused', false).catchError((_) => null);
    await _backgroundTime.invokeMethod('begin').catchError((_) => null); // ~30s so the batch gets queued
    final stopwatch = Stopwatch()..start();
    try {
      await _handOffToBackground(userId);
    } finally {
      _logger.info("Background handoff finished in ${stopwatch.elapsedMilliseconds} ms");
      // Persist before giving the background time back: buffered log lines are lost when iOS suspends us.
      await LogService.I.flush().catchError((_) {});
      unawaited(_backgroundTime.invokeMethod('end').catchError((_) => null));
    }
  }

  static const _backgroundTime = MethodChannel('immich/background_time');

  /// iOS 26.1+: the Photos background-upload extension (ios/UploadExtension). Photos runs it and uploads the
  /// files it registers while the app is suspended or not running, so a lock is no longer limited to one batch.
  static const _uploadExtension = MethodChannel('immich/upload_extension');
  DateTime? _uploadExtensionConfiguredAt;

  /// Hands the extension the current candidate list (it also picks up photos taken later in the selected
  /// albums). Foreground only, at most every 10 min: the candidate query is slow on large libraries.
  Future<void> _configureUploadExtension(String userId) async {
    final last = _uploadExtensionConfiguredAt;
    if (!CurrentPlatform.isIOS || (last != null && DateTime.now().difference(last) < const Duration(minutes: 10))) {
      return;
    }
    _uploadExtensionConfiguredAt = DateTime.now();
    try {
      await Future<void>.delayed(const Duration(seconds: 30)); // let the resume's own queries go first
      // Unhashed too: photos taken just before opening the app are often still hashing at this point, and they
      // predate the change token the extension uses for later additions.
      final candidates = await _foregroundUploadService.getBackupCandidates(userId, onlyHashed: false);
      final albums = await _backgroundUploadService.getAlbumSelection();
      final queued = await _queuedBackgroundAssetIds();
      // null when enabled, otherwise the reason
      final error = await _uploadExtension.invokeMethod<String>('configure', {
        'deviceId': Store.get(StoreKey.deviceId),
        // Leave out what the URLSession queue still holds; the extension would upload it a second time.
        'candidates': [
          for (final asset in candidates)
            if (!queued.contains(asset.id)) asset.id,
        ],
        'checksums': {
          for (final asset in candidates)
            if (asset.checksum != null && !queued.contains(asset.id)) asset.id: asset.checksum,
        },
        'albums': albums.selected,
        'excluded': albums.excluded,
      });
      _logger.info("Upload extension ${error ?? 'enabled'}, ${candidates.length} candidates");
    } catch (error) {
      _uploadExtensionConfiguredAt = null;
      _logger.warning("Could not configure the upload extension", error);
    }
  }

  /// iOS wakes a suspended app only when the whole session queue has drained, so the batch size sets how
  /// often the lock-screen activity can refresh. ponytail: 50 trades a little throughput for twice the updates.
  static const _lockedBatchSize = 50;

  /// Off: foreground pre-queue, refills on background wakes and the remaining-size sample. Together with a
  /// very large library they kept the database busy enough to leave the UI on a spinner (handoffs of up to
  /// 7 min). ponytail: one switch for the whole experiment; flip it back once the library is smaller.
  static const _aggressiveLockedUpload = false;

  /// Batch queued in the background session while in the foreground (not discretionary, so it is what
  /// actually uploads after a lock): up to 300 files and [_foregroundBatchBytes] of temp copies, exported
  /// with a pause between files. ponytail: 500 files / 5 GB exported back to back starved the app of disk
  /// I/O (spinner, 16 s device sync); the pause is the knob if that returns.
  static const _foregroundBatchSize = 300;
  static const _foregroundExportPause = Duration(milliseconds: 250);

  /// Temp-copy budget for the foreground batch: 3 GB, or half the free space if that is less.
  Future<int> _foregroundBatchBytes() async {
    try {
      final free = await _assetSizes.invokeMethod<int>('freeSpace') ?? 0;
      return min(3000000000, free ~/ 2);
    } catch (_) {
      return 1000000000;
    }
  }

  /// Assets this process queued in the background session while in the foreground.
  final _foregroundQueued = <String>{};

  /// Candidates for refills while suspended, prepared in the foreground (see [_schedulePrequeue]).
  List<LocalAsset> _nextCandidates = [];
  DateTime? _lastBackgroundStatus;

  Future<void> _handOffToBackground(String userId) async {
    _bgStatusSubscription ??= _backgroundUploadService.taskStatusStream.listen(_onBackgroundTaskStatus);
    _lastLiveActivity = null; // re-publish as "running"
    // A quick unlock may have restarted the foreground uploader meanwhile; both clear the same tmp dir.
    if (_bgUserId != userId || _cancelToken != null) {
      _logger.info("Background handoff skipped: the app returned to the foreground");
      return;
    }
    // ...and its cancel of the background queue may still be deleting temp files: resuming those tasks now crashes.
    await _bgCancel?.timeout(const Duration(seconds: 20)).catchError((_) => 0);
    // Resume what is queued, and top it up when only a few remain: resuming two leftover tasks and nothing
    // else meant a lock uploaded almost nothing. Counts are refreshed afterwards (a slow query here held a
    // handoff for 29 s of the ~30 s of background time).
    final pending = await _queuedBackgroundAssetIds();
    if (pending.isNotEmpty) {
      unawaited(_backgroundUploadService.resume());
    }
    // The URLSession batch starts within seconds of the lock; the Photos upload extension, which iOS runs much
    // later, takes the rest and new photos. Both run: the extension skips what this queue holds (see below).
    if (pending.length < _handoffTopUpBelow) {
      _logger.info("Background handoff: ${pending.length} queued, adding a batch");
      await _backgroundUploadService.uploadBackupCandidates(
        userId,
        batchSize: _lockedBatchSize,
        clearCache: pending.isEmpty, // queued tasks still read their temp files
        skipAssetIds: pending,
      );
    } else {
      _logger.info("Background handoff: resumed ${pending.length} queued uploads");
    }
    final queued = await _queuedBackgroundAssetIds();
    await _uploadExtension.invokeMethod('setQueued', queued.toList()).catchError((_) => null);
    unawaited(getBackupStatus(userId));
  }

  /// Lock-time handoff adds a batch when fewer than this many uploads are still queued.
  static const _handoffTopUpBelow = 10;

  Future<void> _onBackgroundTaskStatus(TaskStatusUpdate update) async {
    final userId = _bgUserId;
    if (userId == null || !mounted || update.status.isNotFinalState || update.task.group != kBackupGroup) {
      return;
    }
    if (update.status == TaskStatus.complete && update.task.metaData.isNotEmpty) {
      final localAssetId = UploadTaskMetadata.fromJson(update.task.metaData).localAssetId;
      final bytes = await _assetSizes.invokeMethod<int>('total', [localAssetId]).catchError((_) => 0);
      _addUploadedBytes(bytes ?? 0);
    }
    // Refill first: a background wake is short, and the counts below are a database query.
    // The flag is taken before any await: a wake delivers many completions at once.
    if (_aggressiveLockedUpload && !_bgEnqueuing) {
      _bgEnqueuing = true;
      try {
        final remaining = await _queuedBackgroundAssetIds();
        // Refill before the queue is completely empty: iOS wakes a suspended app once per drained session,
        // and a completion delivered after that wake (one straggler) would otherwise leave the chain stuck.
        if (remaining.length <= _refillThreshold) {
          final pool = _nextCandidates.where((asset) => !remaining.contains(asset.id)).toList();
          _logger.info(
            "Background wake: ${remaining.length} uploads still queued, queueing the next batch "
            "(${pool.length} prepared candidates)",
          );
          await _backgroundUploadService.uploadBackupCandidates(
            userId,
            batchSize: _lockedBatchSize,
            clearCache: remaining.isEmpty, // never delete temp files that queued tasks still read
            skipAssetIds: remaining,
            candidates: pool.isEmpty ? null : pool,
          );
          final queuedNow = await _queuedBackgroundAssetIds();
          _nextCandidates.removeWhere((asset) => queuedNow.contains(asset.id));
          await LogService.I.flush().catchError((_) {});
        }
      } finally {
        _bgEnqueuing = false;
      }
    }
    final lastStatus = _lastBackgroundStatus;
    if (lastStatus == null || DateTime.now().difference(lastStatus) > const Duration(seconds: 5)) {
      _lastBackgroundStatus = DateTime.now();
      await getBackupStatus(userId); // live progress for the lock-screen activity
    }
  }

  /// Refill once this few uploads remain in the background session.
  static const _refillThreshold = 5;

  final _logger = Logger("BackupNotifier");

  static const _liveActivity = MethodChannel('immich/backup_live_activity');
  (int, int, bool)? _lastLiveActivity;

  /// Mirrors backup progress into the iOS Live Activity (lock screen / Dynamic Island) and [speedText].
  @override
  set state(BackupState value) {
    super.state = value;
    if (!CurrentPlatform.isIOS || value.totalCount == 0) {
      return;
    }
    final running = _cancelToken != null || _bgUserId != null;
    final now = DateTime.now();
    _updateSpeedText(running, now);

    final current = running
        ? value.uploadItems.values.where((item) => item.progress < 1.0 && item.isFailed != true).firstOrNull
        : null;
    // Foreground only: a suspended app hears about finished files once per drained batch, so a locked
    // "current file" row could never be kept current. The activity shows its own "Updated … ago" instead.
    final fileName = current == null ? null : path.basename(current.filename);
    final fileProgress = current?.progress;
    final key = (value.backupCount, value.totalCount, running);
    final lastPush = _lastLiveActivityPush;
    final fileDue = current != null && (lastPush == null || now.difference(lastPush) >= const Duration(seconds: 1));
    if (key == _lastLiveActivity && !fileDue && fileName == _lastPushedFile) {
      return;
    }
    _lastLiveActivity = key;
    _lastLiveActivityPush = now;
    _lastPushedFile = fileName;
    final args = {
      'done': value.backupCount,
      'total': value.totalCount,
      'paused': !running,
      'start': running,
      'detail': speedText.value,
      'file': fileName,
      'fileProgress': fileProgress,
    };
    // ponytail: progress only while the app runs; a closed app would need APNs push updates (paid team).
    unawaited(_liveActivity.invokeMethod(value.remainderCount <= 0 ? 'end' : 'update', args).catchError((_) => null));
  }

  DateTime? _lastLiveActivityPush;
  String? _lastPushedFile;
  double? _smoothedBytesPerSecond;
  DateTime? _lastSpeedTextAt;

  /// Smoothed (EMA) speed, redrawn at most every 2s, and kept rather than blanked during short gaps.
  void _updateSpeedText(bool running, DateTime now) {
    if (!running) {
      _smoothedBytesPerSecond = null;
      speedText.value = '';
      return;
    }
    final last = _lastSpeedTextAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastSpeedTextAt = now;
    final raw = rawBytesPerSecond(_byteSamples, now);
    final previous = _smoothedBytesPerSecond;
    if (raw != null) {
      _smoothedBytesPerSecond = previous == null ? raw : 0.3 * raw + 0.7 * previous;
    }
    final bytesPerSecond = _smoothedBytesPerSecond;
    if (bytesPerSecond != null) {
      speedText.value = formatSpeedDetail(bytesPerSecond, _remainingBytes);
    }
  }

  /// Same "12.3 MB/s · ~1h 5m left" text as the Live Activity, for the in-app backup page.
  final speedText = ValueNotifier<String>('');

  static const _speedWindow = Duration(seconds: 30);
  static const _assetSizes = MethodChannel('immich/asset_sizes');

  /// Running total of bytes sent, sampled as (time, total) over the last [_speedWindow].
  int _bytesUploaded = 0;
  final _byteSamples = <(DateTime, int)>[];

  /// Foreground: last reported byte count per in-flight asset, to turn progress into deltas.
  final _inFlightBytes = <String, int>{};

  /// Average original size of a remaining candidate, from a sample; × remainderCount gives the bytes left.
  double? _avgCandidateBytes;
  DateTime? _avgMeasuredAt;

  int? get _remainingBytes {
    final avg = _avgCandidateBytes;
    return avg == null ? null : (avg * state.remainderCount).round();
  }

  void _addUploadedBytes(int delta) {
    if (delta <= 0) {
      return;
    }
    _bytesUploaded += delta;
    final now = DateTime.now();
    _byteSamples.add((now, _bytesUploaded));
    _byteSamples.removeWhere((sample) => now.difference(sample.$1) > _speedWindow);
  }

  /// Measures up to 200 candidates spread over the whole list (PhotoKit sizes) instead of all of them:
  /// thousands of lookups take long enough for iOS to suspend the app before an estimate exists.
  /// ponytail: sampled average; exact per-asset sizes only if the ETA proves too coarse.
  Future<void> _refreshRemainingBytes(String userId) async {
    final last = _avgMeasuredAt;
    if (!_aggressiveLockedUpload ||
        !CurrentPlatform.isIOS ||
        _cancelToken == null || // background: the query took 111 s there and starved the refill
        (last != null && DateTime.now().difference(last) < const Duration(minutes: 10))) {
      return;
    }
    final firstRun = last == null;
    _avgMeasuredAt = DateTime.now();
    try {
      if (firstRun) {
        // The candidate query competes with the timeline for the single DB connection; let the app settle.
        await Future<void>.delayed(const Duration(minutes: 2));
        if (!mounted || _cancelToken == null) {
          _avgMeasuredAt = null; // try again on the next foreground status refresh
          return;
        }
      }
      final stopwatch = Stopwatch()..start();
      final candidates = await _foregroundUploadService.getBackupCandidates(userId, onlyHashed: false);
      final sample = sampleEvenly(candidates.map((asset) => asset.id).toList(), 200);
      if (sample.isEmpty) {
        return;
      }
      final bytes = await _assetSizes.invokeMethod<int>('total', sample) ?? 0;
      _avgCandidateBytes = bytes / sample.length;
      _logger.info(
        "Remaining backup ~${(_avgCandidateBytes! * candidates.length / 1e9).toStringAsFixed(1)} GB "
        "(${sample.length} of ${candidates.length} sampled in ${stopwatch.elapsedMilliseconds} ms)",
      );
    } catch (error) {
      _avgMeasuredAt = null; // retry on the next status refresh
      _logger.warning("Could not measure remaining backup size", error);
    }
  }

  /// Up to [count] items spread evenly over [items] (first item included).
  @visibleForTesting
  static List<T> sampleEvenly<T>(List<T> items, int count) {
    if (items.length <= count) {
      return items;
    }
    final step = items.length / count;
    return [for (var i = 0; i < count; i++) items[(i * step).floor()]];
  }

  /// Bytes/s across the samples from the last 30s, or null without enough data (2 samples, 3s apart).
  @visibleForTesting
  static double? rawBytesPerSecond(List<(DateTime, int)> samples, DateTime now) {
    final recent = samples.where((sample) => now.difference(sample.$1) <= _speedWindow).toList();
    if (recent.length < 2) {
      return null;
    }
    final seconds = recent.last.$1.difference(recent.first.$1).inMilliseconds / 1000;
    return seconds < 3 ? null : (recent.last.$2 - recent.first.$2) / seconds;
  }

  /// "12.3 MB/s · ~1h 5m left"; ETA rounded so it does not jitter (5 min steps above an hour).
  @visibleForTesting
  static String formatSpeedDetail(double bytesPerSecond, int? remainingBytes) {
    final speed = '${(bytesPerSecond / 1e6).toStringAsFixed(1)} MB/s';
    if (remainingBytes == null || bytesPerSecond <= 0) {
      return speed;
    }
    final minutes = remainingBytes / bytesPerSecond / 60;
    final String left;
    if (minutes < 1) {
      left = '<1m';
    } else if (minutes < 60) {
      left = '${minutes.round()}m';
    } else {
      final rounded = (minutes / 5).round() * 5;
      left = '${rounded ~/ 60}h ${rounded % 60}m';
    }
    return '$speed · ~$left left';
  }

  /// Remove upload item from state
  void _removeUploadItem(String taskId) {
    if (!mounted) {
      _logger.warning("Skip _removeUploadItem: notifier disposed");
      return;
    }
    if (state.uploadItems.containsKey(taskId)) {
      final updatedItems = Map<String, UploadStatus>.from(state.uploadItems);
      updatedItems.remove(taskId);
      state = state.copyWith(uploadItems: updatedItems);
    }
  }

  Future<void> getBackupStatus(String userId) async {
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (pre-call): notifier disposed");
      return;
    }
    unawaited(_refreshRemainingBytes(userId));
    final counts = await _foregroundUploadService.getBackupCounts(userId);
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (post-call): notifier disposed");
      return;
    }

    state = state.copyWith(
      totalCount: counts.total,
      backupCount: counts.total - counts.remainder,
      remainderCount: counts.remainder,
      processingCount: counts.processing,
    );
  }

  void updateError(BackupError error) {
    if (!mounted) {
      _logger.warning("Skip updateError: notifier disposed");
      return;
    }
    state = state.copyWith(error: error);
  }

  void updateSyncing(bool isSyncing) {
    state = state.copyWith(isSyncing: isSyncing);
  }

  /// Delay before the foreground pre-queue, so its exports stay off the app-start critical path.
  @visibleForTesting
  static Duration prequeueDelay = const Duration(seconds: 20);
  Timer? _prequeueTimer;

  /// Queues a batch in the background session *while in the foreground*: Apple treats transfers created
  /// while the app is in the background as discretionary (iOS parked them for minutes to hours after a
  /// lock), but these keep running promptly once the user locks the phone. Taken from the end of the
  /// candidate list and without clearing the temp dir, so the running foreground upload is unaffected.
  void _schedulePrequeue(String userId) {
    if (_prequeueTimer?.isActive ?? false) {
      return;
    }
    _prequeueTimer = Timer(prequeueDelay, () async {
      if (!mounted || _cancelToken == null) {
        return; // paused meanwhile: the lock-time handoff takes over
      }
      try {
        _foregroundQueued.clear();
        await _backgroundUploadService.uploadBackupCandidates(
          userId,
          batchSize: _foregroundBatchSize,
          fromEnd: true,
          clearCache: false,
          maxBytes: await _foregroundBatchBytes(),
          exportPause: _foregroundExportPause,
          // Recorded per chunk, and only while still in the foreground: a lock part-way leaves the earlier
          // chunks recognised as foreground-created (not replaced on the next open).
          onEnqueued: (ids) {
            if (_cancelToken != null) {
              _foregroundQueued.addAll(ids);
            }
          },
        );
        _logger.info("Pre-queued ${_foregroundQueued.length} background uploads while in the foreground");
        // The next batches' candidates, so a background wake can refill without a database query.
        final all = await _backgroundUploadService.getBackupCandidates(userId);
        _nextCandidates = all.reversed.where((asset) => !_foregroundQueued.contains(asset.id)).take(300).toList();
      } catch (error) {
        _logger.warning("Could not pre-queue background uploads", error);
      }
    });
  }

  /// iOS: keeps a foreground-created background queue, or replaces a discretionary one and schedules a
  /// fresh pre-queue. Returns the asset ids the foreground run must skip.
  Future<Set<String>> _prepareBackgroundQueue(String userId) async {
    var stillQueued = await _queuedBackgroundAssetIds();
    if (!_aggressiveLockedUpload) {
      if (stillQueued.isEmpty) {
        await (_bgCancel = _backgroundUploadService.cancel()); // also cleans up leftover temp files
      } else {
        _logger.info("Keeping ${stillQueued.length} background uploads running");
        unawaited(_backgroundUploadService.resume());
      }
      return stillQueued;
    }
    // Tasks queued while suspended (handoff/refill) are discretionary and get parked by iOS; only keep a
    // queue this process created in the foreground. Others are replaced by a fresh foreground batch.
    final discretionary = stillQueued.difference(_foregroundQueued);
    if (stillQueued.isEmpty || discretionary.isNotEmpty) {
      if (discretionary.isNotEmpty) {
        _logger.info("Replacing ${stillQueued.length} background uploads queued while suspended");
      }
      final cancel = _bgCancel = _backgroundUploadService.cancel();
      await cancel;
      stillQueued = {};
      _schedulePrequeue(userId);
    } else {
      _logger.info("Keeping ${stillQueued.length} background uploads running");
      unawaited(_backgroundUploadService.resume());
    }
    return stillQueued;
  }

  /// Local asset ids of uploads the iOS background session still holds.
  Future<Set<String>> _queuedBackgroundAssetIds() async {
    final queued = await _backgroundUploadService.getActiveTasks(kBackupGroup);
    return {
      for (final task in queued)
        if (task.metaData.isNotEmpty) UploadTaskMetadata.fromJson(task.metaData).localAssetId,
    };
  }

  Future<void> startForegroundBackup(String userId) async {
    // Cancel any existing backup before starting a new one
    if (_cancelToken != null) {
      stopForegroundBackup(reason: "restarting the backup");
    }

    state = state.copyWith(error: BackupError.none);

    // A pause during the recount below nulls _cancelToken, so the run keeps its own reference.
    final cancelToken = Completer<void>();
    _cancelToken = cancelToken;
    _bgUserId = null; // back in the foreground: the foreground uploader takes over
    if (CurrentPlatform.isIOS) {
      // The foreground uploader works through the same list; the extension resumes at the next lock.
      unawaited(_uploadExtension.invokeMethod('setPaused', true).catchError((_) => null));
      unawaited(_configureUploadExtension(userId));
    }

    // iOS: uploads the background session still holds keep running (otherwise every unlock, even a Face ID
    // glance at the lock screen, throws the queue away). The foreground run skips them and leaves the shared
    // temp dir alone. Only an empty queue is cancelled, which also cleans up leftover temp files.
    var stillQueued = <String>{};
    if (CurrentPlatform.isIOS) {
      // Never let a stuck background-queue call hold up the foreground run (and with it the whole resume).
      try {
        stillQueued = await _prepareBackgroundQueue(userId).timeout(const Duration(seconds: 20));
      } on TimeoutException {
        _logger.warning("Background queue check timed out; starting the foreground upload anyway");
        stillQueued = {};
      }
    }

    // Re-baseline the counters against the same DB read that feeds this run's candidate list,
    // otherwise a resume counts duplicate successes against the old baseline (#26215).
    await getBackupStatus(userId);

    return _foregroundUploadService.uploadCandidates(
      userId,
      cancelToken,
      skipAssetIds: stillQueued,
      callbacks: UploadCallbacks(
        onProgress: _handleForegroundBackupProgress,
        onSuccess: _handleForegroundBackupSuccess,
        onError: _handleForegroundBackupError,
        onICloudProgress: _handleICloudProgress,
      ),
    );
  }

  void stopForegroundBackup({required String reason}) {
    // The pre-queue timer is left running: the foreground run restarts every few seconds (hashing, sync), and
    // cancelling here meant it never reached its delay. It checks for a real pause when it fires.
    if (_cancelToken != null) {
      _logger.info("Foreground backup cancelled: $reason");
    }
    _cancelToken?.complete();
    _cancelToken = null;
    _uploadSpeedManager.clear();
    _inFlightBytes.clear(); // a restarted file reports from 0 again; stale counts would undercount it
    state = state.copyWith(uploadItems: {}, iCloudDownloadProgress: {});
  }

  void _handleICloudProgress(String localAssetId, double progress) {
    state = state.copyWith(iCloudDownloadProgress: {...state.iCloudDownloadProgress, localAssetId: progress});

    if (progress >= 1.0) {
      Future.delayed(const Duration(milliseconds: 250), () {
        final updatedProgress = Map<String, double>.from(state.iCloudDownloadProgress);
        updatedProgress.remove(localAssetId);
        state = state.copyWith(iCloudDownloadProgress: updatedProgress);
      });
    }
  }

  void _handleForegroundBackupProgress(String localAssetId, String filename, int bytes, int totalBytes) {
    _addUploadedBytes(bytes - (_inFlightBytes[localAssetId] ?? 0));
    _inFlightBytes[localAssetId] = bytes;
    if (_cancelToken == null) {
      return;
    }

    final progress = totalBytes > 0 ? bytes / totalBytes : 0.0;
    final networkSpeedAsString = _uploadSpeedManager.updateProgress(localAssetId, bytes, totalBytes);
    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(
            filename: filename,
            progress: progress,
            fileSize: totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: UploadStatus(
            taskId: localAssetId,
            filename: filename,
            progress: progress,
            fileSize: totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    }
  }

  void _handleForegroundBackupSuccess(String localAssetId, String remoteAssetId) {
    _inFlightBytes.remove(localAssetId);
    if (!mounted) {
      _logger.warning("Skip _handleForegroundBackupSuccess: notifier disposed");
      return;
    }
    state = state.copyWith(backupCount: state.backupCount + 1, remainderCount: state.remainderCount - 1);
    _uploadSpeedManager.removeTask(localAssetId);

    Future.delayed(const Duration(milliseconds: 1000), () {
      _removeUploadItem(localAssetId);
    });
  }

  void _handleForegroundBackupError(String localAssetId, String errorMessage) {
    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(isFailed: true, error: errorMessage),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: UploadStatus(
            taskId: localAssetId,
            filename: 'Unknown',
            progress: 0,
            fileSize: 0,
            networkSpeedAsString: '',
            isFailed: true,
            error: errorMessage,
          ),
        },
      );
    }

    _uploadSpeedManager.removeTask(localAssetId);
  }

  Future<void> startBackupWithURLSession(String userId, Future<bool> remoteSync, {int batchSize = 100}) async {
    if (!mounted) {
      _logger.warning("Skip handleBackupResume (pre-call): notifier disposed");
      return;
    }
    _logger.info("Start background backup sequence");
    state = state.copyWith(error: BackupError.none);
    final tasks = await _backgroundUploadService.getActiveTasks(kBackupGroup);
    if (!mounted) {
      _logger.warning("Skip handleBackupResume (post-call): notifier disposed");
      return;
    }
    _logger.info("Found ${tasks.length} pending tasks");

    if (tasks.isEmpty) {
      if (!await remoteSync) {
        _logger.warning("Remote sync did not complete successfully, skipping new upload");
        return;
      }
      _logger.info("No pending tasks, starting new upload");
      return _backgroundUploadService.uploadBackupCandidates(userId, batchSize: batchSize);
    }

    _logger.info("Resuming upload ${tasks.length} assets");
    return _backgroundUploadService.resume();
  }
}

final backupCandidateProvider = FutureProvider.autoDispose<List<LocalAsset>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return [];
  }

  return ref.read(foregroundUploadServiceProvider).getBackupCandidates(user.id, onlyHashed: false);
});

final candidateBackupAlbumInfoProvider = FutureProvider.autoDispose.family<List<LocalAlbum>, String>((ref, assetId) {
  return ref
      .read(driftProvider)
      .localAssetRepository
      .getSourceAlbums(assetId, backupSelection: BackupSelection.selected);
});
