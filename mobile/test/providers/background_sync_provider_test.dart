import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';

void main() {
  group('remoteSyncBackupError', () {
    test('a successful sync clears the error', () {
      expect(remoteSyncBackupError(true, AppLifeCycleEnum.resumed), BackupError.none);
    });

    test('a failed sync in the foreground is reported', () {
      expect(remoteSyncBackupError(false, AppLifeCycleEnum.resumed), BackupError.syncFailed);
      expect(remoteSyncBackupError(null, AppLifeCycleEnum.active), BackupError.syncFailed);
    });

    test('a sync cut off by the app leaving the foreground is not reported', () {
      for (final state in [AppLifeCycleEnum.paused, AppLifeCycleEnum.hidden, AppLifeCycleEnum.detached]) {
        expect(remoteSyncBackupError(false, state), BackupError.none, reason: state.name);
      }
    });
  });
}
