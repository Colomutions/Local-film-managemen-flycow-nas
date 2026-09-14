import '../lib/src/library/mdcng_nfo.dart';

void main() {
  const parser = MdcngNfoParser();
  final movie = parser.parse('''
<?xml version="1.0" encoding="UTF-8"?>
<movie>
  <title><![CDATA[ABF-094 测试影片]]></title>
  <originaltitle><![CDATA[ABF-094 Test movie]]></originaltitle>
  <tagline>发行日期: 2024-04-19</tagline>
  <countrycode>JP</countrycode>
  <customrating>JP-18+</customrating>
  <set><name>测试系列</name></set>
  <series>测试系列</series>
  <studio>测试制作商</studio>
  <maker>测试制作商</maker>
  <year>2024</year>
  <outline><![CDATA[测试简介。]]></outline>
  <plot><![CDATA[测试详细简介。]]></plot>
  <runtime>157</runtime>
  <poster>poster.jpg</poster>
  <thumb>thumb.jpg</thumb>
  <fanart>fanart.jpg</fanart>
  <actor><name>测试演员</name><type>Actor</type></actor>
  <actor><name>另一位演员</name></actor>
  <publisher>测试发行</publisher>
  <label>测试发行</label>
  <tag>题材</tag>
  <tag>演员标签</tag>
  <genre>题材</genre>
  <genre>高清</genre>
  <num>ABF-094</num>
  <premiered>2024-04-19</premiered>
  <releasedate>2024-04-19</releasedate>
  <release>2024-04-19</release>
  <cover>https://example.invalid/cover.jpg</cover>
  <website>https://example.invalid/video</website>
</movie>
''');

  _expect(movie.catalogNumber == 'ABF-094', '读取番号');
  _expect(movie.title == 'ABF-094 测试影片', '读取 CDATA 标题');
  _expect(movie.originalTitle == 'ABF-094 Test movie', '读取原始标题');
  _expect(movie.plot == '测试详细简介。', '读取简介');
  _expect(movie.runtimeMinutes == 157, '读取时长');
  _expect(movie.setName == '测试系列' && movie.series == '测试系列', '读取系列');
  _expect(movie.studio == '测试制作商', '读取制作商');
  _expect(movie.publisher == '测试发行', '读取发行商');
  _expect(
    movie.actors.map((actor) => actor.name).join('|') == '测试演员|另一位演员',
    '读取多个演员',
  );
  _expect(
    movie.tagsAndGenres.join('|') == '题材|演员标签|高清',
    '标签和类型按名称去重且保持顺序',
  );
  _expect(
    movie.poster == 'poster.jpg' &&
        movie.fanart == 'fanart.jpg' &&
        movie.thumb == 'thumb.jpg',
    '读取同目录图片引用',
  );

  _expectFormat(
    () => parser.parse('<series><title>错误根节点</title></series>'),
    '拒绝非 movie 根节点',
  );
  _expectFormat(() => parser.parse('<movie>'), '拒绝损坏 XML');
}

void _expectFormat(void Function() action, String description) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('Assertion failed: $description');
}

void _expect(bool condition, String description) {
  if (!condition) throw StateError('Assertion failed: $description');
}
