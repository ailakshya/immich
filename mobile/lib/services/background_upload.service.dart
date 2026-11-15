import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' as api;
import 'package:path/path.dart' as p;

part 'background_upload.service.freezed.dart';

final backgroundUploadServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    db.localAssetRepository,
    db.backupRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

/// Metadata for upload tasks to track live photo handling
@Freezed(fromJson: false, toJson: false)
abstract class UploadTaskMetadata with _$UploadTaskMetadata {
  const UploadTaskMetadata._();

  const factory UploadTaskMetadata({
    required String localAssetId,
    required bool isLivePhotos,
    required String livePhotoVideoId,
    String? checksum,
  }) = _UploadTaskMetadata;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      'checksum': checksum,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      checksum: map['checksum'] as String?,
    );
  }

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  String toJson() => json.encode(toMap());
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._assetMediaRepository,
    this._assetService,
  ) {
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final LocalAssetRepository _localAssetRepository;
  final BackupRepository _backupRepository;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();

  // ignore: unused-code
  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  // ignore: unused-code
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
    unawaited(_handleTaskStatusUpdate(update));
  }

  void dispose() {
    unawaited(_taskStatusController.close());
    unawaited(_taskProgressController.close());
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks) {
    return _uploadRepository.enqueueBackgroundAll(tasks);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Finds backup candidates, builds upload tasks, and enqueues them
  /// for background processing.
  /// [fromEnd]: take the batch from the end of the candidate list, so it does not overlap a foreground run
  /// working from the front. [clearCache] must be false while a foreground run has temp files in flight.
  /// [skipAssetIds] are left out (already queued). [maxBytes] caps the exported temp copies; tasks are enqueued every 50, so a lock part-way through
  /// still leaves the earlier chunks queued from the foreground. [exportPause] spaces the exports out and
  /// [onEnqueued] reports each enqueued chunk's asset ids.
  Future<void> uploadBackupCandidates(
    String userId, {
    int batchSize = 100,
    bool fromEnd = false,
    bool clearCache = true,
    int? maxBytes,
    Set<String> skipAssetIds = const {},
    List<LocalAsset>? candidates,
    Duration exportPause = Duration.zero,
    void Function(Iterable<String> assetIds)? onEnqueued,
  }) async {
    // One batch at a time: a second call would clear the temp dir (and reset the abort flag) while the first
    // is still exporting and enqueueing, and NSURLSession aborts the app on a task whose file is gone.
    while (_queueing != null) {
      await _queueing;
    }
    final queueing = Completer<void>();
    _queueing = queueing.future;
    try {
      await _uploadBackupCandidates(
        userId,
        batchSize: batchSize,
        fromEnd: fromEnd,
        clearCache: clearCache,
        maxBytes: maxBytes,
        skipAssetIds: skipAssetIds,
        candidates: candidates,
        exportPause: exportPause,
        onEnqueued: onEnqueued,
      );
    } finally {
      _queueing = null;
      queueing.complete();
    }
  }

  /// Backup candidates, for preparing a later background batch while still in the foreground.
  Future<List<LocalAsset>> getBackupCandidates(String userId) => _backupRepository.getCandidates(userId);

  Future<({List<String> selected, List<String> excluded})> getAlbumSelection() => _backupRepository.getAlbumSelection();

  /// The batch currently being exported and enqueued, if any.
  Future<void>? _queueing;

  Future<void> _uploadBackupCandidates(
    String userId, {
    required int batchSize,
    required bool fromEnd,
    required bool clearCache,
    required int? maxBytes,
    required Set<String> skipAssetIds,
    required List<LocalAsset>? candidates,
    required Duration exportPause,
    required void Function(Iterable<String> assetIds)? onEnqueued,
  }) async {
    if (clearCache) {
      await _storageRepository.clearCache();
    }
    shouldAbortQueuingTasks = false;

    // [skipAssetIds]: assets still queued in the session; they stay candidates until the server has them.
    // [candidates]: a list prepared in the foreground; querying the database from a short background wake
    // can take longer than iOS allows.
    final source = candidates ?? await _backupRepository.getCandidates(userId);
    final pending = source.where((asset) => !skipAssetIds.contains(asset.id)).toList();
    if (pending.isEmpty) {
      _logger.info("No new backup candidates found, finishing background upload");
      return;
    }

    _logger.info("Found ${pending.length} backup candidates for background tasks");

    final List<UploadTask> tasks = [];
    Future<void> enqueuePending() async {
      // Last line of defence: never hand NSURLSession a task whose temp file has disappeared (it throws an
      // Objective-C exception and aborts the app).
      final ready = [
        for (final task in tasks)
          if (File(await task.filePath()).existsSync()) task,
      ];
      if (ready.length < tasks.length) {
        _logger.warning("Skipped ${tasks.length - ready.length} upload tasks whose temp file is gone");
      }
      if (ready.isNotEmpty && !shouldAbortQueuingTasks) {
        _logger.info("Enqueuing ${ready.length} background upload tasks");
        await enqueueTasks(ready);
        onEnqueued?.call(ready.map((task) => UploadTaskMetadata.fromJson(task.metaData).localAssetId));
      }
      tasks.clear();
    }

    var count = 0;
    var bytes = 0;
    for (final asset in fromEnd ? pending.reversed : pending) {
      if (count >= batchSize || (maxBytes != null && bytes >= maxBytes) || shouldAbortQueuingTasks) {
        break;
      }
      final task = await getUploadTask(asset);
      if (task == null) {
        continue;
      }
      tasks.add(task);
      count++;
      if (maxBytes != null) {
        bytes += await File(await task.filePath()).length().catchError((_) => 0);
      }
      if (tasks.length >= 50) {
        await enqueuePending();
      }
      if (exportPause > Duration.zero) {
        await Future<void>.delayed(exportPause); // leave disk and database to the app between exports
      }
    }
    await enqueuePending();
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  Future<int> cancel() async {
    final stopwatch = Stopwatch()..start();
    void step(String name) => _logger.info("cancel: $name after ${stopwatch.elapsedMilliseconds} ms");
    shouldAbortQueuingTasks = true;
    await _queueing; // let an in-flight batch stop before its files are deleted
    step("in-flight batch stopped");
    // Drop the queue before its files: a task still queued for a deleted temp file makes
    // NSURLSession throw in uploadTask(with:fromFile:) and aborts the app.
    await _uploadRepository.reset(kBackupGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupGroup);
    await _uploadRepository.reset(kBackupLivePhotoGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupLivePhotoGroup);
    step("queue reset");
    await _storageRepository.clearCache();
    step("temp files cleared");

    final activeTasks = await _uploadRepository.getActiveTasks(kBackupGroup);
    return activeTasks.length;
  }

  /// Resume background backup processing
  Future<void> resume() {
    return _uploadRepository.start();
  }

  Future<void> _handleTaskStatusUpdate(TaskStatusUpdate update) async {
    switch (update.status) {
      case TaskStatus.complete:
        unawaited(_handleLivePhoto(update));
        unawaited(_stackEditedAsset(update));

        if (CurrentPlatform.isIOS) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } catch (e) {
            _logger.severe('Error deleting file path for iOS: $e');
          }
        }

      default:
        break;
    }
  }

  Future<void> _handleLivePhoto(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.task.metaData == '') {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      if (!metadata.isLivePhotos) {
        return;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }

      final uploadTask = await getLivePhotoUploadTask(localAsset, response['id'] as String);

      if (uploadTask == null) {
        return;
      }

      await enqueueTasks([uploadTask]);
    } catch (error, stackTrace) {
      dPrint(() => "Error handling live photo upload task: $error $stackTrace");
    }
  }

  Future<void> _stackEditedAsset(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      // The video half of a live photo carries isLivePhotos; the still that follows is the final asset
      if (metadata.isLivePhotos) {
        return;
      }

      await _assetService.stackEditedUpload(
        metadata.localAssetId,
        jsonDecode(update.responseBody!)['id'] as String,
        metadata.checksum,
      );
    } catch (error, stackTrace) {
      dPrint(() => "Error stacking edited asset upload: $error $stackTrace");
    }
  }

  @visibleForTesting
  Future<UploadTask?> getUploadTask(LocalAsset asset, {String group = kBackupGroup, int? priority}) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning("Asset entity not found for ${asset.id} - ${asset.name}");
      return null;
    }

    File? file;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.

    if (entity.isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning("Failed to get file for asset ${asset.id} - ${asset.name}");
      return null;
    }

    final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
    final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
    final originalFileName = p.setExtension(fileName, extension);

    final String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: entity.isLivePhoto,
      livePhotoVideoId: '',
      checksum: asset.checksum,
    ).toJson();

    final requiresWiFi = _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
      fields: entity.isLivePhoto ? {'visibility': api.AssetVisibility.hidden.toString()} : null,
      cloudId: entity.isLivePhoto ? null : asset.cloudId,
      adjustmentTime: entity.isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: entity.isLivePhoto ? null : asset.latitude?.toString(),
      longitude: entity.isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(LocalAsset asset, String livePhotoVideoId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: UploadTaskMetadata(
        localAssetId: asset.id,
        isLivePhotos: false,
        livePhotoVideoId: livePhotoVideoId,
        checksum: asset.checksum,
      ).toJson(),
      fields: fields,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      ...?fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }
}
