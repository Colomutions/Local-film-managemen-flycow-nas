import 'dart:io';

import '../lib/src/library/taxonomy_transfer.dart';
import '../lib/src/library_database.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mujing-taxonomy-test-');
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
    _expect(first.added.length == 7, 'four definitions and three relationships are added');

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
    _expect(repeated.skipped.isNotEmpty, 'same tag transfer reports skipped entries');

    final tags = {for (final tag in database.listTags()) tag.name: tag};
    final placements = database.listTagPlacements();
    final scifi = tags['科幻']!;
    final scifiPlacement = placements.singleWhere((item) => item.tagId == scifi.id);
    _expect(
      database.deleteTagPlacement(scifiPlacement.id),
      'deleting the last child relation deletes the child tag',
    );
    _expect(database.findTag(scifi.id) == null, 'last relation removal deletes child');

    final subject = tags['题材']!;
    _expect(database.deleteTagWithTaxonomyRules(subject.id), 'root is deleted');
    _expect(database.findTag(tags['冷峻']!.id) != null, 'multi-parent child is preserved');
    _expect(database.taxonomyViolations().isEmpty, 'root deletion leaves a valid taxonomy');

    final exported = database.exportTagTaxonomy();
    _expect(exported.roots.single.name == '氛围', 'only remaining root is exported');
    _expect(
      exported.children.single.parents.single == '氛围',
      'remaining child parent is exported',
    );
    _expect(
      NasTagTaxonomyTransfer.decode(exported.toJson()).children.single.name == '冷峻',
      'tag JSON round trips',
    );
    _expect(
      NasCategoryTaxonomyTransfer.decode(database.exportCategoryTaxonomy().toJson())
              .categories
              .length ==
          2,
      'category JSON round trips',
    );
  } finally {
    await database.close();
    await directory.delete(recursive: true);
  }
}

void _expect(bool value, String description) {
  if (!value) throw StateError('Assertion failed: $description');
}
