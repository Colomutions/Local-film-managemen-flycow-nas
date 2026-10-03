import 'dart:io';

import '../lib/src/library/mdcng_actor_source.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
        'Usage: dart run tool/mdcng_actor_photo_audit.dart <config/data>');
    exitCode = 64;
    return;
  }

  final records = await NasMdcngActorSource(args.single).readCompletedActors();
  final marked = records.where((record) => record.hasPhoto).toList();
  final found = records.where((record) => record.photo != null).toList();
  final missing = marked.where((record) => record.photo == null).toList();
  final ownersByImage = <String, List<String>>{};
  for (final record in records) {
    final photo = record.photo;
    if (photo == null) continue;
    ownersByImage.putIfAbsent(photo.file.path, () => []).add(record.sourceName);
  }
  final shared = ownersByImage.entries
      .where((entry) => entry.value.length > 1)
      .toList(growable: false);
  final tasksByEmbyId = <String, List<String>>{};
  for (final record in records) {
    tasksByEmbyId.putIfAbsent(record.embyId, () => []).add(record.taskId);
  }
  final sharedEmbyIds = tasksByEmbyId.entries
      .where((entry) => entry.value.length > 1)
      .toList(growable: false);
  stdout.writeln('Completed actors: ${records.length}');
  stdout.writeln('MDCNG marked with portrait: ${marked.length}');
  stdout.writeln('Portrait files matched: ${found.length}');
  stdout.writeln('Marked with portrait but unmatched: ${missing.length}');
  stdout
      .writeln('Portrait files assigned to multiple actors: ${shared.length}');
  stdout.writeln('Emby person IDs shared by tasks: ${sharedEmbyIds.length}');
  for (final entry in sharedEmbyIds.take(10)) {
    stdout.writeln('  ${entry.key}: ${entry.value.join(', ')}');
  }
  for (final entry in shared.take(10)) {
    stdout.writeln('  ${entry.key}: ${entry.value.join(', ')}');
  }
  for (final record in missing.take(20)) {
    stdout.writeln('  ${record.taskId}: ${record.sourceName}'
        ' (profile: ${record.profile?.name ?? '-'},'
        ' images: ${record.images.map((image) => image.fileName).join(', ')})');
  }
}
