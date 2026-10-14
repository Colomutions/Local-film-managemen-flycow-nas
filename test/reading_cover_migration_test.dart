import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../lib/src/comics/comic_catalog.dart';
import '../lib/src/library/schema_repository.dart';
import '../lib/src/novels/novel_repository.dart';
import 'comic_api_test.dart' show check;

Future<void> main() async {
  final novels = sqlite3.openInMemory();
  final root =
      await Directory.systemTemp.createTemp('reading-cover-migration-');
  final catalog = ComicCatalog(root.path);
  try {
    migrateNovelSchema(novels);
    novels.execute('ALTER TABLE novels DROP COLUMN cover_base64');
    novels.execute(
        'CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)');
    novels.execute("INSERT INTO schema_migrations VALUES(34,'2026-10-01')");
    NasSchemaRepository(() => novels).migrate();
    check(
        novels
            .select('PRAGMA table_info(novels)')
            .any((row) => row['name'] == 'cover_base64'),
        'old novel schema gains cover');
    check(
        novels
                .select('SELECT MAX(version) AS n FROM schema_migrations')
                .single['n'] ==
            35,
        'migration records version');
    NasSchemaRepository(() => novels).migrate();

    await catalog.open();
    final original = <String, Object?>{
      'title': '旧漫画',
      'author': '作者',
      'format': 'cbz',
      'fileName': '旧漫画.cbz',
      'relativePath': '',
      'sizeBytes': 5,
      'contentSha256': 'a' * 64
    };
    catalog.commitCreate(
        metadata: original,
        deviceId: 'device',
        key: 'old',
        semanticDigest: 'old',
        quotaBytes: null);
    final id = catalog.byContent('a' * 64, 'cbz')!.id;
    catalog.db.execute('ALTER TABLE comics DROP COLUMN cover_base64');
    catalog.close();
    await catalog.open();
    check(
        catalog.find(id)!.coverBase64 == null &&
            catalog.find(id)!.title == '旧漫画',
        'old comic survives migration');
    const cover =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=';
    catalog.commitCreate(
        metadata: {...original, 'coverBase64': cover},
        deviceId: 'device',
        key: 'with-cover',
        semanticDigest: 'with-cover',
        quotaBytes: null);
    check(
        catalog.find(id)!.coverBase64 == cover &&
            catalog.find(id)!.revision == 2,
        'dedup adds missing cover and revision');
    final changed = catalog.commitReplace(
        id: id,
        revision: 2,
        metadata: {...original, 'coverBase64': 'changed-cover'},
        deviceId: 'admin',
        key: 'replace',
        semanticDigest: 'replace',
        quotaBytes: null);
    check(
        (changed['body'] as Map)['data']['changed'] == true &&
            catalog.find(id)!.revision == 3,
        'cover-only replace increments revision');
    catalog.commitReplace(
        id: id,
        revision: 3,
        metadata: {...original, 'title': '新标题'},
        deviceId: 'admin',
        key: 'without-cover',
        semanticDigest: 'without-cover',
        quotaBytes: null);
    check(catalog.find(id)!.coverBase64 == 'changed-cover',
        'legacy replacement preserves cover');
    print('reading_cover_migration_test: PASS');
  } finally {
    catalog.close();
    novels.dispose();
    await root.delete(recursive: true);
  }
}
