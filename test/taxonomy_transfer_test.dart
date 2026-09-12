import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library/taxonomy_transfer.dart';
import '../lib/src/library_database.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-taxonomy-test-');
  final databasePath =
      '${directory.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite';
  await Directory('${directory.path}${Platform.pathSeparator}db').create();
  _createVersion19TaxonomyDatabase(databasePath);

  final database = NasLibraryDatabase(directory.path);
  await database.open();
  try {
    _expect(database.listTags().isEmpty, '升级仅清理旧标签数据');

    final genre = database.createTag(
      name: '题材',
      level: 1,
      description: '影片题材',
      color: '#654321',
    );
    final mood = database.createTag(name: '氛围', level: 1);
    final crime = database.createTag(
      name: '刑侦',
      level: 2,
      parentIds: [genre.id, mood.id],
    );
    final deduction = database.createTag(
      name: '本格推理',
      level: 3,
      description: '重视线索与逻辑的推理类型',
      parentIds: [crime.id],
    );
    _expect(crime.level == 2 && deduction.level == 3, '三级固定层级被保存');
    _expect(
      database.tagDetails(tagId: deduction.id)?.parents.single.id == crime.id,
      '三级标签返回直接父级',
    );
    _expect(
      database
          .tagDirectory()
          .singleWhere((item) => item.tag.id == genre.id)
          .children
          .any((item) => item.tag.id == crime.id),
      '二级多父级显示在第一个一级目录下',
    );
    _expect(
      database
          .tagDirectory()
          .singleWhere((item) => item.tag.id == mood.id)
          .children
          .any((item) => item.tag.id == crime.id),
      '二级多父级显示在第二个一级目录下',
    );
    _expect(
      _throwsArgument(() => database.createTag(name: ' 题材', level: 1)),
      '标签名称拒绝首尾空白',
    );
    _expect(
      _throwsArgument(
        () => database.createTag(name: '题材', level: 2, parentIds: [genre.id]),
      ),
      '标签名称全局唯一',
    );
    _expect(
      _throwsArgument(
        () => database.updateTag(
          tagId: deduction.id,
          name: deduction.name,
          description: deduction.description,
          color: deduction.color,
          parentIds: const [],
        ),
      ),
      '不允许移除三级标签最后一个父级',
    );
    _expect(
      _throwsState(() => database.deleteTag(genre.id)),
      '存在子级标签时只能归档',
    );
    _expect(database.archiveTag(genre.id), '归档标签成功');
    _expect(
      !database.listTags().any((item) => item.id == genre.id),
      '归档标签不出现在默认候选集',
    );

    final validTransfer = const NasTagTaxonomyTransfer(
      tags: [
        NasTaxonomyTagDefinition(name: '地区', level: 1, color: '#654321'),
        NasTaxonomyTagDefinition(name: '时代', level: 1),
        NasTaxonomyTagDefinition(name: '欧洲', level: 2, parents: ['地区']),
        NasTaxonomyTagDefinition(name: '战后', level: 2, parents: ['时代']),
        NasTaxonomyTagDefinition(
          name: '法国黑色电影',
          level: 3,
          parents: ['欧洲', '战后'],
        ),
      ],
    );
    final imported = database.importTagTaxonomy(validTransfer);
    _expect(imported.conflicts.isEmpty, '三级导入没有冲突');
    _expect(imported.added.length == 9, '导入写入五个实体和四条多父归属');
    final importedTags = {
      for (final tag in database.listTags()) tag.name: tag,
    };
    _expect(importedTags['地区']!.color == '#654321', '标签导入保留文件中的显式颜色');
    _expect(
      [
        '时代',
        '欧洲',
        '战后',
        '法国黑色电影',
      ].every(
        (name) => const {
          '#ffc266',
          '#58d5ff',
          '#73d8a4',
          '#b59aff',
          '#ff8eaa',
        }.contains(importedTags[name]!.color),
      ),
      '缺省标签颜色由 NAS 随机补齐',
    );
    final repeated = database.importTagTaxonomy(validTransfer);
    _expect(repeated.added.isEmpty && repeated.skipped.isNotEmpty, '重复导入安全跳过');

    final invalidTransfer = NasTagTaxonomyTransfer.decode({
      'format': 'mujing-tags',
      'version': 2,
      'tags': [
        {'name': '角色混用', 'level': 1},
        {
          'name': '角色混用',
          'level': 2,
          'parents': ['地区']
        },
      ],
    });
    _expect(invalidTransfer.validationConflicts.length == 1, '导入先发现层级角色混用');
    final rejected = database.importTagTaxonomy(invalidTransfer);
    _expect(
        rejected.added.isEmpty && rejected.conflicts.length == 1, '冲突导入整体不写库');
    _expect(
      !database
          .listTags(includeArchived: true)
          .any((tag) => tag.name == '角色混用'),
      '冲突标签没有部分写入',
    );
    final wrongParent = NasTagTaxonomyTransfer.decode({
      'format': 'mujing-tags',
      'version': 2,
      'tags': [
        {
          'name': '越级子级',
          'level': 3,
          'parents': ['地区']
        },
      ],
    });
    _expect(
      database.importTagTaxonomy(wrongParent).conflicts.isNotEmpty,
      '导入拒绝既有标签的跨层归属',
    );

    final batchRoot = database.createTag(name: '性能根', level: 1);
    final largeTransfer = NasTagTaxonomyTransfer(
      tags: List.generate(
        1200,
        (index) => NasTaxonomyTagDefinition(
          name: '性能二级 ${index.toString().padLeft(4, '0')}',
          level: 2,
          parents: const ['性能根'],
        ),
      ),
    );
    final stopwatch = Stopwatch()..start();
    final largeResult = database.importTagTaxonomy(largeTransfer);
    stopwatch.stop();
    _expect(largeResult.conflicts.isEmpty, '大样本导入没有冲突');
    _expect(largeResult.added.length == 2400, '大样本批量写入实体和归属');
    _expect(stopwatch.elapsed < const Duration(seconds: 20), '大样本批量导入在合理时间内完成');
    final firstPage = database.tagChildren(parentTagId: batchRoot.id, page: 1);
    final secondPage = database.tagChildren(parentTagId: batchRoot.id, page: 2);
    _expect(firstPage.items.length == 10 && secondPage.items.length == 10,
        '直属子标签固定十条分页');
    _expect(firstPage.total == 1200 && firstPage.hasMore, '直属子标签返回正确分页元数据');

    _expect(
      NasTagTaxonomyTransfer.decode(database.exportTagTaxonomy().toJson())
          .tags
          .isNotEmpty,
      '三级标签导出和导入格式可以往返解析',
    );

    final categoryImport = database.importCategoryTaxonomy(
      const NasCategoryTaxonomyTransfer(
        categories: [
          NasTaxonomyCategoryDefinition(name: '导入随机分类'),
          NasTaxonomyCategoryDefinition(name: '导入固定分类', color: '#123456'),
        ],
      ),
    );
    _expect(categoryImport.conflicts.isEmpty, '分类导入没有冲突');
    final importedCategories = {
      for (final category in database.listCategories()) category.name: category,
    };
    _expect(
      const {
        '#1677FF',
        '#8B5CF6',
        '#0FAF8F',
        '#E86A33',
        '#E5484D',
        '#D89B16',
      }.contains(importedCategories['导入随机分类']!.color),
      '缺省分类颜色由 NAS 随机补齐',
    );
    _expect(
      importedCategories['导入固定分类']!.color == '#123456',
      '分类导入保留文件中的显式颜色',
    );
  } finally {
    await database.close();
  }

  final migrated = sqlite3.open(databasePath);
  try {
    final names = migrated
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    _expect(!names.contains('tag_placements'), '旧路径归属表已定向移除');
    _expect(!names.contains('movie_tag_placements'), '旧影片路径关联表已定向移除');
    _expect(
        names.contains('tag_parent_links') && names.contains('movie_tag_links'),
        '新概念关联表已创建');
    _expect(
      migrated.select('SELECT COUNT(*) AS count FROM movies').single['count'] ==
          1,
      '升级不会删除影片记录',
    );
  } finally {
    migrated.dispose();
    await directory.delete(recursive: true);
  }

  stdout.writeln('taxonomy_transfer_test: PASS');
}

void _createVersion19TaxonomyDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
      INSERT INTO schema_migrations(version, applied_at) VALUES (19, '2026-09-11T00:00:00Z');
      CREATE TABLE movies (
        id TEXT PRIMARY KEY,
        category_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      INSERT INTO movies(id, created_at, updated_at)
        VALUES ('preserved-movie', '2026-01-01', '2026-01-01');
      CREATE TABLE media_roots (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        last_scanned_at TEXT
      );
      CREATE TABLE episodes (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL,
        relative_path TEXT NOT NULL
      );
      CREATE TABLE library_categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color TEXT,
        media_relative_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE playback_history (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL,
        episode_id TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        end_position_ms INTEGER,
        duration_ms INTEGER
      );
      CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        color TEXT
      );
      CREATE TABLE tag_placements (
        id TEXT PRIMARY KEY,
        tag_id TEXT NOT NULL,
        parent_placement_id TEXT
      );
      CREATE TABLE movie_tag_placements (
        movie_id TEXT NOT NULL,
        tag_placement_id TEXT NOT NULL
      );
      INSERT INTO tags(id, name, created_at, updated_at) VALUES ('legacy-tag', '旧标签', '2026-01-01', '2026-01-01');
      INSERT INTO tag_placements(id, tag_id) VALUES ('legacy-placement', 'legacy-tag');
      INSERT INTO movie_tag_placements(movie_id, tag_placement_id) VALUES ('preserved-movie', 'legacy-placement');
    ''');
  } finally {
    database.dispose();
  }
}

bool _throwsArgument(void Function() action) {
  try {
    action();
  } on ArgumentError {
    return true;
  }
  return false;
}

bool _throwsState(void Function() action) {
  try {
    action();
  } on StateError {
    return true;
  }
  return false;
}

void _expect(bool condition, String description) {
  if (!condition) throw StateError('Assertion failed: $description');
}
