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

class NasTaxonomyTagDefinition {
  const NasTaxonomyTagDefinition({
    required this.name,
    this.color,
    this.parents = const [],
  });

  final String name;
  final String? color;
  final List<String> parents;

  Map<String, Object> toJson({required bool child}) => {
        'name': name,
        if (color != null) 'color': color!,
        if (child) 'parents': parents,
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
        !map.keys.toSet().containsAll(const {'format', 'version', 'categories'}) ||
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
  const NasTagTaxonomyTransfer({required this.roots, required this.children});

  final List<NasTaxonomyTagDefinition> roots;
  final List<NasTaxonomyTagDefinition> children;

  Map<String, Object> toJson() => {
        'format': 'mujing-tags',
        'version': 1,
        'tags': {
          'roots': roots.map((item) => item.toJson(child: false)).toList(),
          'children': children.map((item) => item.toJson(child: true)).toList(),
        },
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static NasTagTaxonomyTransfer decode(Object? value) {
    if (value is! Map) throw const FormatException('根节点必须是对象');
    final map = Map<String, dynamic>.from(value);
    if (!_hasOnly(map, const {'format', 'version', 'tags'}) ||
        !map.keys.toSet().containsAll(const {'format', 'version', 'tags'}) ||
        map['format'] != 'mujing-tags' ||
        map['version'] != 1 ||
        map['tags'] is! Map) {
      throw const FormatException('不是幕境标签定义文件');
    }
    final tags = Map<String, dynamic>.from(map['tags'] as Map);
    if (!_hasOnly(tags, const {'roots', 'children'}) ||
        !tags.keys.toSet().containsAll(const {'roots', 'children'}) ||
        tags['roots'] is! List ||
        tags['children'] is! List) {
      throw const FormatException('tags 只能包含 roots 和 children');
    }
    final roots = _definitions(tags['roots'], '一级标签')
        .map((item) => NasTaxonomyTagDefinition(
              name: item.name,
              color: item.color,
            ))
        .toList(growable: false);
    final children = <NasTaxonomyTagDefinition>[];
    for (final raw in tags['children'] as List) {
      if (raw is! Map) throw const FormatException('二级标签必须是对象');
      final item = Map<String, dynamic>.from(raw);
      if (!_hasOnly(item, const {'name', 'color', 'parents'}) ||
          !item.containsKey('name') ||
          !item.containsKey('parents') ||
          item['name'] is! String ||
          (item['color'] != null && item['color'] is! String) ||
          item['parents'] is! List) {
        throw const FormatException('二级标签结构无效');
      }
      final name = _requiredName(item['name'], '二级标签');
      final color = item['color'] as String?;
      if (!isValidTaxonomyColor(color)) {
        throw const FormatException('颜色必须是 #RRGGBB');
      }
      final parents = <String>[];
      final seenParents = <String>{};
      for (final rawParent in item['parents'] as List) {
        final parent = _requiredName(rawParent, '二级标签父级');
        if (!seenParents.add(normalizeTaxonomyName(parent))) {
          throw const FormatException('二级标签父级不能重复');
        }
        parents.add(parent);
      }
      if (parents.isEmpty) throw const FormatException('二级标签至少需要一个一级归属');
      children.add(NasTaxonomyTagDefinition(
        name: name,
        color: color,
        parents: parents,
      ));
    }
    final rootNames = <String>{};
    for (final root in roots) {
      if (!rootNames.add(normalizeTaxonomyName(root.name))) {
        throw const FormatException('一级标签名称不能重复（不区分大小写）');
      }
    }
    final allNames = <String>{...rootNames};
    for (final child in children) {
      if (!allNames.add(normalizeTaxonomyName(child.name))) {
        throw const FormatException('标签名称或角色冲突（不区分大小写）');
      }
      if (child.parents.any(
        (parent) => !rootNames.contains(normalizeTaxonomyName(parent)),
      )) {
        throw const FormatException('二级标签引用了未知一级标签');
      }
    }
    return NasTagTaxonomyTransfer(roots: roots, children: children);
  }

  static NasTagTaxonomyTransfer decodeText(String source) => decode(jsonDecode(source));
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
