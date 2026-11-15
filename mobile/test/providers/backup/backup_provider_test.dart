import 'dart:async';

import 'package:background_downloader/background_downloader.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

class MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class MockBackgroundUploadService extends Mock implements BackgroundUploadService {}

void main() {
  BackupNotifier.prequeueDelay = Duration.zero;
  speedDetailChecks();
  late MockForegroundUploadService foregroundUploadService;
  late MockBackgroundUploadService backgroundUploadService;
  late BackupNotifier notifier;

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
    registerFallbackValue(<String>{});
    registerFallbackValue(Duration.zero);
  });

  setUp(() {
    foregroundUploadService = MockForegroundUploadService();
    backgroundUploadService = MockBackgroundUploadService();
    notifier = BackupNotifier(foregroundUploadService, backgroundUploadService, UploadSpeedManager());
    addTearDown(() {
      if (notifier.mounted) {
        notifier.dispose();
      }
    });
  });

  void mockCounts({required int total, required int remainder, int processing = 0}) {
    when(
      () => foregroundUploadService.getBackupCounts('user-1'),
    ).thenAnswer((_) async => (total: total, remainder: remainder, processing: processing));
  }

  // Drives a backup run so we can grab the onSuccess callback the notifier wires up.
  Future<void Function(String, String)> startAndCaptureOnSuccess() async {
    void Function(String, String)? onSuccess;
    when(
      () => foregroundUploadService.uploadCandidates(
        any(),
        any(),
        callbacks: any(named: 'callbacks'),
        skipAssetIds: any(named: 'skipAssetIds'),
      ),
    ).thenAnswer((invocation) async {
      onSuccess = (invocation.namedArguments[#callbacks] as UploadCallbacks).onSuccess;
    });
    await notifier.startForegroundBackup('user-1');
    return onSuccess!;
  }

  group('foreground backup counts', () {
    test('successes move one asset from remainder to backup', () async {
      mockCounts(total: 25, remainder: 25);
      final onSuccess = await startAndCaptureOnSuccess();

      for (var i = 0; i < 10; i++) {
        onSuccess('asset-$i', 'remote-$i');
      }

      expect(notifier.state.remainderCount, 15);
      expect(notifier.state.backupCount, 10);
      expect(notifier.state.backupCount + notifier.state.remainderCount, notifier.state.totalCount);
    });

    test('a duplicate success after pause and resume cannot go below zero', () async {
      // #26215: app pauses mid-backup, sync has not recorded the upload yet, so the
      // resumed run re-uploads the same asset and the server answers 200 duplicate.
      // The start of each run re-baselines the counters from the DB, so the duplicate
      // success is counted against a baseline that includes the asset again.
      mockCounts(total: 1, remainder: 1);

      final firstRun = await startAndCaptureOnSuccess();
      expect(notifier.state.remainderCount, 1);
      firstRun('asset-1', 'remote-1');
      expect(notifier.state.remainderCount, 0);

      notifier.stopForegroundBackup(reason: "test");

      final resumedRun = await startAndCaptureOnSuccess();
      expect(notifier.state.remainderCount, 1);
      verify(() => foregroundUploadService.getBackupCounts('user-1')).called(2);

      resumedRun('asset-1', 'remote-1');
      expect(notifier.state.remainderCount, 0);
      expect(notifier.state.backupCount, 1);
    });

    test('a drifted counter state heals at run start', () async {
      mockCounts(total: 91, remainder: 7);
      notifier.state = notifier.state.copyWith(totalCount: 91, backupCount: 103, remainderCount: -12);

      await startAndCaptureOnSuccess();

      expect(notifier.state.totalCount, 91);
      expect(notifier.state.remainderCount, 7);
      expect(notifier.state.backupCount, 84);
    });

    test('on iOS uploads start only after the background queue is cancelled', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockCounts(total: 1, remainder: 1);
      final cancel = Completer<int>();
      when(() => backgroundUploadService.getActiveTasks(any())).thenAnswer((_) async => []);
      when(() => backgroundUploadService.cancel()).thenAnswer((_) => cancel.future);
      when(
        () => backgroundUploadService.uploadBackupCandidates(
          any(),
          batchSize: any(named: 'batchSize'),
          fromEnd: any(named: 'fromEnd'),
          clearCache: any(named: 'clearCache'),
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).thenAnswer((_) async {});

      final backup = notifier.startForegroundBackup('user-1');
      await pumpEventQueue();
      verifyNever(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      );

      cancel.complete(0);
      await backup;
      verify(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).called(1);
    });

    test('on iOS a foreground start with an empty queue pre-queues a background batch and skips it', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockCounts(total: 2, remainder: 2);
      const meta = UploadTaskMetadata(localAssetId: 'prequeued', isLivePhotos: false, livePhotoVideoId: '');
      var enqueued = false;
      when(() => backgroundUploadService.getActiveTasks(any())).thenAnswer(
        (_) async =>
            enqueued ? [UploadTask(url: 'https://x/api/assets', filename: 'a.jpg', metaData: meta.toJson())] : [],
      );
      when(() => backgroundUploadService.cancel()).thenAnswer((_) async => 0);
      when(
        () => backgroundUploadService.uploadBackupCandidates(
          any(),
          batchSize: any(named: 'batchSize'),
          fromEnd: any(named: 'fromEnd'),
          clearCache: any(named: 'clearCache'),
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).thenAnswer((_) async => enqueued = true);
      when(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).thenAnswer((_) async {});

      await notifier.startForegroundBackup('user-1');
      await pumpEventQueue();

      // the foreground run starts right away (nothing to skip yet); the batch is queued afterwards
      verify(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: {},
        ),
      ).called(1);
      verify(
        () => backgroundUploadService.uploadBackupCandidates(
          'user-1',
          batchSize: 300,
          fromEnd: true,
          clearCache: false,
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).called(1);
    }, skip: 'pre-queue experiment is switched off (_aggressiveLockedUpload)');

    test('on iOS a later foreground start keeps its own queue and skips its assets', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockCounts(total: 2, remainder: 2);
      const meta = UploadTaskMetadata(localAssetId: 'queued-asset', isLivePhotos: false, livePhotoVideoId: '');
      var enqueued = false;
      when(() => backgroundUploadService.getActiveTasks(any())).thenAnswer(
        (_) async =>
            enqueued ? [UploadTask(url: 'https://x/api/assets', filename: 'a.jpg', metaData: meta.toJson())] : [],
      );
      when(() => backgroundUploadService.cancel()).thenAnswer((_) async => 0);
      when(() => backgroundUploadService.resume()).thenAnswer((_) async {});
      when(
        () => backgroundUploadService.uploadBackupCandidates(
          any(),
          batchSize: any(named: 'batchSize'),
          fromEnd: any(named: 'fromEnd'),
          clearCache: any(named: 'clearCache'),
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).thenAnswer((invocation) async {
        enqueued = true;
        (invocation.namedArguments[#onEnqueued] as void Function(Iterable<String>)?)?.call(['queued-asset']);
      });
      when(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).thenAnswer((_) async {});

      await notifier.startForegroundBackup('user-1');
      await pumpEventQueue(times: 200); // pre-queue fires and records the foreground batch
      await notifier.startForegroundBackup('user-1'); // e.g. after a Face ID glance

      verify(() => backgroundUploadService.cancel()).called(1); // only the first start
      verify(
        () => backgroundUploadService.uploadBackupCandidates(
          any(),
          batchSize: any(named: 'batchSize'),
          fromEnd: any(named: 'fromEnd'),
          clearCache: any(named: 'clearCache'),
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).called(1);
      verify(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: {'queued-asset'},
        ),
      ).called(1);
    }, skip: 'pre-queue experiment is switched off (_aggressiveLockedUpload)');

    test('on iOS uploads queued while suspended are replaced by a foreground batch', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockCounts(total: 2, remainder: 2);
      const leftover = UploadTaskMetadata(localAssetId: 'leftover', isLivePhotos: false, livePhotoVideoId: '');
      when(() => backgroundUploadService.getActiveTasks(any())).thenAnswer(
        (_) async => [UploadTask(url: 'https://x/api/assets', filename: 'a.jpg', metaData: leftover.toJson())],
      );
      when(() => backgroundUploadService.cancel()).thenAnswer((_) async => 0);
      when(
        () => backgroundUploadService.uploadBackupCandidates(
          any(),
          batchSize: any(named: 'batchSize'),
          fromEnd: any(named: 'fromEnd'),
          clearCache: any(named: 'clearCache'),
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).thenAnswer((_) async {});

      await notifier.startForegroundBackup('user-1');
      await pumpEventQueue();

      verify(() => backgroundUploadService.cancel()).called(1);
      verify(
        () => backgroundUploadService.uploadBackupCandidates(
          'user-1',
          batchSize: 300,
          fromEnd: true,
          clearCache: false,
          maxBytes: any(named: 'maxBytes'),
          exportPause: any(named: 'exportPause'),
          onEnqueued: any(named: 'onEnqueued'),
        ),
      ).called(1);
    }, skip: 'pre-queue experiment is switched off (_aggressiveLockedUpload)');

    test('on iOS a foreground start keeps any background queue and skips its assets', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockCounts(total: 2, remainder: 2);
      const meta = UploadTaskMetadata(localAssetId: 'queued-asset', isLivePhotos: false, livePhotoVideoId: '');
      when(
        () => backgroundUploadService.getActiveTasks(any()),
      ).thenAnswer((_) async => [UploadTask(url: 'https://x/api/assets', filename: 'a.jpg', metaData: meta.toJson())]);
      when(() => backgroundUploadService.resume()).thenAnswer((_) async {});
      when(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: any(named: 'skipAssetIds'),
        ),
      ).thenAnswer((_) async {});

      await notifier.startForegroundBackup('user-1');
      await pumpEventQueue();

      verifyNever(() => backgroundUploadService.cancel());
      verify(
        () => foregroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          skipAssetIds: {'queued-asset'},
        ),
      ).called(1);
    });

    test('a late success after dispose does not throw', () async {
      mockCounts(total: 2, remainder: 2);
      final onSuccess = await startAndCaptureOnSuccess();
      notifier.dispose();

      onSuccess('asset-1', 'remote-1');
    });
  });
}

void speedDetailChecks() {
  final t0 = DateTime(2026, 11, 14, 12);
  (DateTime, int) at(int seconds, int bytes) => (t0.add(Duration(seconds: seconds)), bytes);
  DateTime after(int seconds) => t0.add(Duration(seconds: seconds));

  test('rawBytesPerSecond needs 2 samples 3s apart within the last 30s', () {
    expect(BackupNotifier.rawBytesPerSecond([], after(0)), isNull);
    expect(BackupNotifier.rawBytesPerSecond([at(0, 0)], after(0)), isNull);
    expect(BackupNotifier.rawBytesPerSecond([at(0, 0), at(1, 5000000)], after(1)), isNull);
    expect(BackupNotifier.rawBytesPerSecond([at(0, 0), at(10, 50000000)], after(60)), isNull);
    expect(BackupNotifier.rawBytesPerSecond([at(0, 0), at(10, 120000000)], after(10)), 12000000);
  });

  test('sampleEvenly spreads the sample over the whole list', () {
    expect(BackupNotifier.sampleEvenly([1, 2, 3], 5), [1, 2, 3]);
    final sample = BackupNotifier.sampleEvenly(List.generate(1000, (i) => i), 4);
    expect(sample, [0, 250, 500, 750]);
  });

  test('formatSpeedDetail rounds the ETA so it does not jitter', () {
    expect(BackupNotifier.formatSpeedDetail(12e6, null), '12.0 MB/s');
    expect(BackupNotifier.formatSpeedDetail(12e6, 60000000), '12.0 MB/s · ~<1m left');
    expect(BackupNotifier.formatSpeedDetail(12e6, 7200000000), '12.0 MB/s · ~10m left');
    // 101 min and 103 min both show 1h 45m / 1h 40m in 5-minute steps
    expect(BackupNotifier.formatSpeedDetail(1e6, 101 * 60 * 1000000), '1.0 MB/s · ~1h 40m left');
    expect(BackupNotifier.formatSpeedDetail(1e6, 103 * 60 * 1000000), '1.0 MB/s · ~1h 45m left');
  });
}
