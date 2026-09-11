import 'dart:convert';

String normalizeTaxonomyName(String value) => value.trim().toLowerCase();

bool isValidTaxonomyColor(String? value) =>
    value == null || RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value);

class NasTaxonomyCategoryDefinition {
  const NasTaxonomyCategoryDefinition({required this.name, this.color});

  final String name;
  final String? color;

  Map<String, Object> toJson() => {
        'name': name,
        if (color != null) 'color': color!,
      };
}

/// 标签导入定义以实体层级和父实体名称表达，不再使用路径位置。
class NasTaxonomyTagDefinition {
  const NasTaxonomyTagDefinition({
    required this.name,
    required this.level,
    this.description = '',
    this.color,
    this.parents = const [],
  });

  final String name;
  final int level;
  final String description;
  final String? color;
  final List<String> parents;

  Map<String, Object> toJson() => {
        'name': name,
        'level': level,
        if (description.isNotEmpty) 'description': description,
        if (color != null) 'color': color!,
        if (level > 1) 'parents': parents,
      };
}

class NasCategoryTaxonomyTransfer {
  const NasCategoryTaxonomyTransfer({required this.categories});

  final List<NasTaxonomyCategoryDefinition> categories;

  Map<String, Object> toJson() => {
        'format': 'mujing-categories',
        'version': 1,
        'categories': categories.map((item) => item.toJson()).toList(),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static NasCategoryTaxonomyTransfer decode(Object? value) {
    if (value is! Map) throw const FormatException('根节点必须是对象');
    final map = Map<String, dynamic>.from(value);
    if (!_hasOnly(map, const {'format', 'version', 'categories'}) ||
        !map.keys
            .toSet()
            .containsAll(const {'format', 'version', 'categories'}) ||
        map['format'] != 'mujing-categories' ||
        map['version'] != 1 ||
        map['categories'] is! List) {
      throw const FormatException('不是幕境分类定义文件');
    }
    return NasCategoryTaxonomyTransfer(
      categories: _definitions(map['categories'], '分类'),
    );
  }

  static NasCategoryTaxonomyTransfer decodeText(String source) =>
      decode(jsonDecode(source));
}

class NasTagTaxonomyTransfer {
  const NasTagTaxonomyTransfer({
    required this.tags,
    this.sourceSkipped = const [],
    this.validationConflicts = const [],
  });

  final List<NasTaxonomyTagDefinition> tags;
  final List<String> sourceSkipped;
  final List<String> validationConflicts;

  Map<String, Object> toJson() => {
        'format': 'mujing-tags',
        'version': 2,
        'tags': tags.map((item) => item.toJson()).toList(),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static NasTagTaxonomyTransfer decode(Object? value) {
    if (value is! Map) throw const FormatException('根节点必须是对象');
    final map = Map<String, dynamic>.from(value);
    if (!_hasOnly(map, const {'format', 'version', 'tags'}) ||
        !map.keys.toSet().containsAll(const {'format', 'version', 'tags'}) ||
        map['format'] != 'mujing-tags' ||
        map['version'] != 2 ||
        map['tags'] is! List) {
      throw const FormatException('不是三级幕境标签定义文件');
    }

    final skipped = <String>[];
    final conflicts = <String>[];
    final definitions = <NasTaxonomyTagDefinition>[];
    final levelsByName = <String, int>{};

    for (final raw in map['tags'] as List) {
      if (raw is! Map) throw const FormatException('标签项必须是对象');
      final item = Map<String, dynamic>.from(raw);
      if (!_hasOnly(item, const {'name', 'description', 'color', 'level', 'parents'}) ||
          !item.containsKey('name') ||
          !item.containsKey('level') ||
          item['name'] is! String ||
          item['level'] is! int ||
          (item['description'] != null && item['description'] is! String) ||
          (item['color'] != null && item['color'] is! String) ||
          (item['parents'] != null && item['parents'] is! List)) {
        throw const FormatException('标签项结构无效');
      }
      final name = _requiredName(item['name'], '标签');
      final level = item['level'] as int;
      final description = (item['description'] as String? ?? '').trim();
      final color = item['color'] as String?;
      if (level < 1 || level > 3 || !isValidTaxonomyColor(color)) {
        throw const FormatException('标签层级或颜色无效');
      }

      final parents = <String>[];
      final seenParents = <String>{};
      for (final rawParent in item['parents'] as List? ?? const []) {
        final parent = _requiredName(rawParent, '标签父级');
        final parentKey = normalizeTaxonomyName(parent);
        if (!seenParents.add(parentKey)) {
          skipped.add('标签归属（文件重复）：$parent → $name');
          continue;
        }
        parents.add(parent);
      }
      if (level == 1 && parents.isNotEmpty) {
        conflicts.add('一级标签不能指定父级：$name');
        continue;
      }
      if (level > 1 && parents.isEmpty) {
        conflicts.add('${_levelName(level)}标签缺少有效父级：$name');
        continue;
      }

      final key = normalizeTaxonomyName(name);
      final existingLevel = levelsByName[key];
      if (existingLevel != null) {
        if (existingLevel != level) {
          conflicts.add('标签层级冲突：$name 同时定义为${_levelName(existingLevel)}和${_levelName(level)}标签');
        } else {
          skipped.add('${_levelName(level)}标签（文件重复）：$name');
        }
        continue;
      }
      levelsByName[key] = level;
      definitions.add(NasTaxonomyTagDefinition(
        name: name,
        level: level,
        description: description,
        color: color,
        parents: parents,
      ));
    }

    for (final definition in definitions) {
      if (definition.level == 1) continue;
      for (final parent in definition.parents) {
        final parentLevel = levelsByName[normalizeTaxonomyName(parent)];
        if (parentLevel != null && parentLevel != definition.level - 1) {
          conflicts.add(
            '${_levelName(definition.level)}标签父级层级错误：$parent → ${definition.name}',
          );
        }
      }
    }
    return NasTagTaxonomyTransfer(
      tags: definitions,
      sourceSkipped: skipped,
      validationConflicts: conflicts,
    );
  }

  static NasTagTaxonomyTransfer decodeText(String source) =>
      decode(jsonDecode(source));
}

class NasTaxonomyTransferResult {
  const NasTaxonomyTransferResult({
    required this.added,
    required this.skipped,
    required this.conflicts,
  });

  final List<String> added;
  final List<String> skipped;
  final List<String> conflicts;

  Map<String, Object> toJson() => {
        'added': added,
        'skipped': skipped,
        'conflicts': conflicts,
      };
}

bool _hasOnly(Map<String, dynamic> value, Set<String> allowed) =>
    value.keys.every(allowed.contains);

List<NasTaxonomyCategoryDefinition> _definitions(Object? raw, String label) {
  if (raw is! List) throw FormatException('$label 必须是数组');
  final result = <NasTaxonomyCategoryDefinition>[];
  final names = <String>{};
  for (final value in raw) {
    if (value is! Map) throw FormatException('$label 项必须是对象');
    final item = Map<String, dynamic>.from(value);
    if (!_hasOnly(item, const {'name', 'color'}) ||
        !item.containsKey('name') ||
        item['name'] is! String ||
        (item['color'] != null && item['color'] is! String)) {
      throw FormatException('$label 项结构无效');
    }
    final name = _requiredName(item['name'], label);
    final color = item['color'] as String?;
    if (!isValidTaxonomyColor(color)) {
      throw const FormatException('颜色必须是 #RRGGBB');
    }
    if (!names.add(normalizeTaxonomyName(name))) {
      throw FormatException('$label 名称不能重复（不区分大小写）');
    }
    result.add(NasTaxonomyCategoryDefinition(name: name, color: color));
  }
  return result;
}

String _requiredName(Object? value, String label) {
  if (value is! String || value.trim().isEmpty || value != value.trim()) {
    throw FormatException('$label 名称不能为空或含首尾空白');
  }
  return value;
}

String _levelName(int level) => switch (level) {
      1 => '一级',
      2 => '二级',
      3 => '三级',
      _ => '未知',
    };
