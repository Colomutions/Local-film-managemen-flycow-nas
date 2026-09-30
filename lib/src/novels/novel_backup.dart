import 'dart:io';

import 'package:crypto/crypto.dart';

import '../backup_service.dart';
import 'novel_models.dart';
import 'novel_repository.dart';
import 'novel_storage.dart';
import 'novel_write_barrier.dart';

class NasNovelBackupCoordinator {
  const NasNovelBackupCoordinator({
    required this.repository,
    required this.storage,
    required this.writeBarrier,
    this.backgroundRead,
  });

  final NasNovelRepository repository;
  final NasNovelStorage storage;
  final NasNovelWriteBarrier writeBarrier;
  final Stream<List<int>> Function(Stream<List<int>> source)? backgroundRead;

  Stream<List<int>> _read(File file) {
    final source = file.openRead();
    return backgroundRead?.call(source) ?? source;
  }

  Future<NasPreparedBackupContribution> prepare({
    required String backupId,
    required Directory temporaryDirectory,
    required File databaseTarget,
    required Future<void> Function(File target) databaseSnapshot,
  }) async {
    List<NasNovelBackupEntry>? entries;
    try {
      await writeBarrier.runCapture(() async {
        entries = repository.beginBackupJob(backupId);
        await databaseSnapshot(databaseTarget);
      });
      final captured = entries!;
      final copied = <String>{};
      for (final entry in captured) {
        if (!copied.add(entry.contentSha256)) continue;
        final source = storage.objectFile(entry.contentSha256);
        final target = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}novels'
          '${Platform.pathSeparator}objects${Platform.pathSeparator}'
          '${entry.contentSha256}',
        );
        await target.parent.create(recursive: true);
        final digestOutput = _BackupDigestSink();
        final digestInput = sha256.startChunkedConversion(digestOutput);
        var copiedBytes = 0;
        final sink = target.openWrite(mode: FileMode.writeOnly);
        try {
          await sink.addStream(_read(source).map((bytes) {
            digestInput.add(bytes);
            copiedBytes += bytes.length;
            return bytes;
          }));
          digestInput.close();
          if (copiedBytes != entry.sizeBytes || digestOutput.value?.toString() != entry.contentSha256) {
            throw StateError('Novel source content failed backup validation');
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        await _verifyCopy(target, entry);
      }
      return NasPreparedBackupContribution(
        manifestFields: {
          'novels': {
            'version': 1,
            'items':
                captured.map((entry) => entry.toJson()).toList(growable: false),
          },
        },
        complete: () async {
          final digests = repository.completeBackupJob(backupId);
          for (final digest in digests) {
            await storage.deleteUnreferencedObject(digest);
          }
        },
        abandon: () async {
          final digests = repository.abandonBackupJob(backupId);
          for (final digest in digests) {
            await storage.deleteUnreferencedObject(digest);
          }
        },
      );
    } catch (_) {
      if (entries != null) {
        final digests = repository.abandonBackupJob(backupId);
        for (final digest in digests) {
          await storage.deleteUnreferencedObject(digest);
        }
      }
      rethrow;
    }
  }

  Future<void> _verifyCopy(File file, NasNovelBackupEntry entry) async {
    if (await file.length() != entry.sizeBytes) {
      throw StateError('Novel backup copy has an invalid size.');
    }
    final digest = await sha256.bind(_read(file)).first;
    if (digest.toString() != entry.contentSha256) {
      throw StateError('Novel backup copy has an invalid digest.');
    }
  }
}

class _BackupDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
