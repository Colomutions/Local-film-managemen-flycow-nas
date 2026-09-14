import 'package:xml/xml.dart';

class MdcngNfoMovie {
  const MdcngNfoMovie({
    this.title,
    this.originalTitle,
    this.sortTitle,
    this.tagline,
    this.countryCode,
    this.customRating,
    this.mpaa,
    this.setName,
    this.series,
    this.studio,
    this.maker,
    this.year,
    this.outline,
    this.plot,
    this.originalPlot,
    this.runtimeMinutes,
    this.poster,
    this.thumb,
    this.fanart,
    this.publisher,
    this.label,
    this.catalogNumber,
    this.premiered,
    this.releaseDate,
    this.release,
    this.coverUrl,
    this.website,
    this.actors = const [],
    this.tags = const [],
    this.genres = const [],
  });

  final String? title;
  final String? originalTitle;
  final String? sortTitle;
  final String? tagline;
  final String? countryCode;
  final String? customRating;
  final String? mpaa;
  final String? setName;
  final String? series;
  final String? studio;
  final String? maker;
  final String? year;
  final String? outline;
  final String? plot;
  final String? originalPlot;
  final int? runtimeMinutes;
  final String? poster;
  final String? thumb;
  final String? fanart;
  final String? publisher;
  final String? label;
  final String? catalogNumber;
  final String? premiered;
  final String? releaseDate;
  final String? release;
  final String? coverUrl;
  final String? website;
  final List<MdcngNfoActor> actors;
  final List<String> tags;
  final List<String> genres;

  List<String> get tagsAndGenres => _uniqueText([...tags, ...genres]);
}

class MdcngNfoActor {
  const MdcngNfoActor({required this.name, this.type});

  final String name;
  final String? type;
}

class MdcngNfoParser {
  const MdcngNfoParser();

  MdcngNfoMovie parse(String source) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlParserException catch (error) {
      throw FormatException('MDCNG NFO XML 无法解析：${error.message}');
    }

    final movie = document.rootElement;
    if (movie.name.local != 'movie') {
      throw const FormatException('MDCNG NFO 根节点必须是 movie。');
    }

    final set = _child(movie, 'set');
    return MdcngNfoMovie(
      title: _text(movie, 'title'),
      originalTitle: _text(movie, 'originaltitle'),
      sortTitle: _text(movie, 'sorttitle'),
      tagline: _text(movie, 'tagline'),
      countryCode: _text(movie, 'countrycode'),
      customRating: _text(movie, 'customrating'),
      mpaa: _text(movie, 'mpaa'),
      setName: set == null ? null : _text(set, 'name') ?? _clean(set.innerText),
      series: _text(movie, 'series'),
      studio: _text(movie, 'studio'),
      maker: _text(movie, 'maker'),
      year: _text(movie, 'year'),
      outline: _text(movie, 'outline'),
      plot: _text(movie, 'plot'),
      originalPlot: _text(movie, 'originalplot'),
      runtimeMinutes: int.tryParse(_text(movie, 'runtime') ?? ''),
      poster: _text(movie, 'poster'),
      thumb: _text(movie, 'thumb'),
      fanart: _text(movie, 'fanart'),
      publisher: _text(movie, 'publisher'),
      label: _text(movie, 'label'),
      catalogNumber: _text(movie, 'num'),
      premiered: _text(movie, 'premiered'),
      releaseDate: _text(movie, 'releasedate'),
      release: _text(movie, 'release'),
      coverUrl: _text(movie, 'cover'),
      website: _text(movie, 'website'),
      actors: _actors(movie),
      tags: _values(movie, 'tag'),
      genres: _values(movie, 'genre'),
    );
  }
}

XmlElement? _child(XmlElement parent, String name) {
  for (final child in parent.children.whereType<XmlElement>()) {
    if (child.name.local == name) return child;
  }
  return null;
}

String? _text(XmlElement parent, String name) {
  final element = _child(parent, name);
  return _clean(element?.innerText);
}

List<MdcngNfoActor> _actors(XmlElement movie) {
  final actors = <MdcngNfoActor>[];
  for (final actor in movie.children.whereType<XmlElement>()) {
    if (actor.name.local != 'actor') continue;
    final name = _text(actor, 'name');
    if (name != null) {
      actors.add(MdcngNfoActor(name: name, type: _text(actor, 'type')));
    }
  }
  return actors;
}

List<String> _values(XmlElement movie, String name) => _uniqueText(
      movie.children
          .whereType<XmlElement>()
          .where((element) => element.name.local == name)
          .map((element) => _clean(element.innerText)),
    );

String? _clean(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

List<String> _uniqueText(Iterable<String?> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final normalized = _clean(value);
    if (normalized == null || !seen.add(normalized.toLowerCase())) continue;
    result.add(normalized);
  }
  return result;
}
