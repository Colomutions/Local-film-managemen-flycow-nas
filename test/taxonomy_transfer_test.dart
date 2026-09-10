import 'dart:io';

import '../lib/src/library/taxonomy_transfer.dart';
import '../lib/src/library_database.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-taxonomy-test-');
  final database = NasLibraryDatabase(directory.path);
  await database.open();
  try {
    final categories = database.importCategoryTaxonomy(
      const NasCategoryTaxonomyTransfer(
        categories: [
          NasTaxonomyCategoryDefinition(name: '电影', color: '#123456'),
          NasTaxonomyCategoryDefinition(name: '剧集'),
        ],
      ),
    );
    _expect(categories.conflicts.isEmpty, 'valid categories have no conflicts');
    _expect(categories.added.length == 2, 'two categories are added');
    _expect(
      database
              .listCategories()
              .singleWhere((item) => item.name == '电影')
              .color ==
          '#123456',
      'category color is persisted',
    );
    _expect(
      database.listCategories().every((item) => item.mediaRelativePath == null),
      'imported NAS categories stay unbound and do not imply a scan',
    );

    final first = database.importTagTaxonomy(
      const NasTagTaxonomyTransfer(
        roots: [
          NasTaxonomyTagDefinition(name: '题材', color: '#654321'),
          NasTaxonomyTagDefinition(name: '氛围'),
        ],
        children: [
          NasTaxonomyTagDefinition(name: '科幻', parents: ['题材']),
          NasTaxonomyTagDefinition(name: '冷峻', parents: ['题材', '氛围']),
        ],
      ),
    );
    _expect(first.conflicts.isEmpty, 'valid tags have no conflicts');
    _expect(first.added.length == 7,
        'four definitions and three relationships are added');
    _expect(tagsAreColored(database), 'tag color is persisted');

    final repeated = database.importTagTaxonomy(
      const NasTagTaxonomyTransfer(
        roots: [
          NasTaxonomyTagDefinition(name: '题材'),
          NasTaxonomyTagDefinition(name: '氛围'),
        ],
        children: [
          NasTaxonomyTagDefinition(name: '科幻', parents: ['题材']),
          NasTaxonomyTagDefinition(name: '冷峻', parents: ['题材', '氛围']),
        ],
      ),
    );
    _expect(repeated.added.isEmpty, 'same tag transfer performs no writes');
    _expect(repeated.skipped.isNotEmpty,
        'same tag transfer reports skipped entries');

    final tags = {for (final tag in database.listTags()) tag.name: tag};
    final placements = database.listTagPlacements();
    final scifi = tags['科幻']!;
    final scifiPlacement =
        placements.singleWhere((item) => item.tagId == scifi.id);
    _expect(
      database.deleteTagPlacement(scifiPlacement.id),
      'deleting the last child relation deletes the child tag',
    );
    _expect(database.findTag(scifi.id) == null,
        'last relation removal deletes child');

    final subject = tags['题材']!;
    _expect(database.deleteTagWithTaxonomyRules(subject.id), 'root is deleted');
    _expect(database.findTag(tags['冷峻']!.id) != null,
        'multi-parent child is preserved');
    _expect(database.taxonomyViolations().isEmpty,
        'root deletion leaves a valid taxonomy');

    final exported = database.exportTagTaxonomy();
    _expect(
        exported.roots.single.name == '氛围', 'only remaining root is exported');
    _expect(
      exported.children.single.parents.single == '氛围',
      'remaining child parent is exported',
    );
    _expect(
      NasTagTaxonomyTransfer.decode(exported.toJson()).children.single.name ==
          '冷峻',
      'tag JSON round trips',
    );
    _expect(
      NasCategoryTaxonomyTransfer.decode(
                  database.exportCategoryTaxonomy().toJson())
              .categories
              .length ==
          2,
      'category JSON round trips',
    );

    final duplicateSource = NasTagTaxonomyTransfer.decode({
      'format': 'mujing-tags',
      'version': 1,
      'tags': {
        'roots': [
          {'name': '格式'},
          {'name': '格式'},
        ],
        'children': [
          {
            'name': '高清',
            'parents': ['格式', '格式'],
          },
          {
            'name': '高清',
            'parents': ['格式'],
          },
        ],
      },
    });
    _expect(duplicateSource.roots.length == 1,
        'duplicate roots keep the first definition');
    _expect(duplicateSource.children.length == 1,
        'duplicate children keep the first definition');
    _expect(
      duplicateSource.sourceSkipped.length == 3,
      'duplicate source definitions and relationships are reported as skipped',
    );
    final duplicateResult = database.importTagTaxonomy(duplicateSource);
    _expect(duplicateResult.conflicts.isEmpty,
        'duplicate source definitions do not block import');
    _expect(
      duplicateResult.skipped.length >= 3,
      'duplicate source definitions are returned to the client as skipped',
    );
    _expect(
      database.listTags().any((item) => item.name == '高清'),
      'the first duplicate child definition is imported',
    );

    final hierarchyConflict = NasTagTaxonomyTransfer.decode({
      'format': 'mujing-tags',
      'version': 1,
      'tags': {
        'roots': [
          {'name': '层级'},
        ],
        'children': [
          {
            'name': '层级',
            'parents': ['层级'],
          },
          {
            'name': '孤儿',
            'parents': ['不存在的一级标签'],
          },
        ],
      },
    });
    _expect(
      hierarchyConflict.validationConflicts.length == 2,
      'ambiguous parent-child definitions are collected before import',
    );
    final hierarchyResult = database.importTagTaxonomy(hierarchyConflict);
    _expect(
        hierarchyResult.added.isEmpty, 'hierarchy conflicts block all writes');
    _expect(
      hierarchyResult.conflicts.length == 2,
      'hierarchy conflicts are returned for the Windows reminder',
    );
    _expect(
      !database
          .listTags()
          .any((item) => item.name == '层级' || item.name == '孤儿'),
      'blocked hierarchy definitions do not create tags',
    );
  } finally {
    await database.close();
    await directory.delete(recursive: true);
  }
}

bool tagsAreColored(NasLibraryDatabase database) =>
    database.listTags().singleWhere((item) => item.name == '题材').color ==
    '#654321';

void _expect(bool value, String description) {
  if (!value) throw StateError('Assertion failed: $description');
}
