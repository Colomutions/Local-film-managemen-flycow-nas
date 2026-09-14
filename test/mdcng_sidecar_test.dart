import 'dart:io';

import '../lib/src/library/mdcng_sidecar.dart';
import '../lib/src/media_service.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mdcng-sidecar-test-');
  try {
    final video = File(
      directory.path + Platform.pathSeparator + 'ABF-094-SD.mp4',
    );
    await video.writeAsBytes(const [0]);
    final nfo = File(
      directory.path + Platform.pathSeparator + 'ABF-094-SD.nfo',
    );
    await nfo.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<movie>
  <title>ABF-094 测试影片</title>
  <num>ABF-094</num>
  <poster>poster.jpg</poster>
  <fanart>fanart.jpg</fanart>
  <thumb>thumb.jpg</thumb>
</movie>
''');
    for (final name in const ['poster.jpg', 'fanart.jpg', 'thumb.jpg']) {
      await File(directory.path + Platform.pathSeparator + name)
          .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    }

    const reader = MdcngNfoSidecarReader();
    final sidecar = await reader.readForVideo(
      NasMediaFile(video, 'test-library/ABF-094/ABF-094-SD.mp4'),
    );
    _expect(sidecar.nfoFileName == 'ABF-094-SD.nfo', '按视频基名找 NFO');
    _expect(sidecar.nfoContentHash.length == 64, '为预览版本生成 NFO 内容摘要');
    _expect(sidecar.movie.catalogNumber == 'ABF-094', '读取 NFO 数据');
    _expect(
      sidecar.artwork.map((item) => item.kind.wireName).join('|') ==
          'poster|fanart|thumb',
      '读取三类同目录图片',
    );
    _expect(sidecar.issues.isEmpty, '正常侧车文件没有告警');
    final posterBytes = await reader.readArtworkBytes(
      video: NasMediaFile(video, 'test-library/ABF-094/ABF-094-SD.mp4'),
      artwork: sidecar.artwork.first,
    );
    _expect(posterBytes.length == 4, '确认导入前重新校验本地图片');

    await nfo.writeAsString('''
<movie>
  <title>ABF-094 测试影片</title>
  <poster>../outside.jpg</poster>
</movie>
''');
    final unsafeSidecar = await reader.readForVideo(
      NasMediaFile(video, 'test-library/ABF-094/ABF-094-SD.mp4'),
    );
    _expect(
      unsafeSidecar.issues.any(
        (issue) =>
            issue.code == 'invalid_artwork_path' && issue.field == 'poster',
      ),
      '拒绝离开影片目录的图片引用',
    );

    await nfo.writeAsString('''
<movie>
  <title>ABF-094 测试影片</title>
  <poster>..\\outside.jpg</poster>
</movie>
''');
    final windowsUnsafeSidecar = await reader.readForVideo(
      NasMediaFile(video, 'test-library/ABF-094/ABF-094-SD.mp4'),
    );
    _expect(
      windowsUnsafeSidecar.issues.any(
        (issue) =>
            issue.code == 'invalid_artwork_path' && issue.field == 'poster',
      ),
      '拒绝 Windows 分隔符形式的图片路径',
    );

    await nfo.delete();
    await _expectSidecarCode(
      () => reader.readForVideo(
        NasMediaFile(video, 'test-library/ABF-094/ABF-094-SD.mp4'),
      ),
      'sidecar_not_found',
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> _expectSidecarCode(
  Future<void> Function() action,
  String expectedCode,
) async {
  try {
    await action();
  } on MdcngNfoSidecarException catch (error) {
    if (error.code == expectedCode) return;
    throw StateError(
      'Assertion failed: 预期错误码 ' + expectedCode + '，实际为 ' + error.code,
    );
  }
  throw StateError('Assertion failed: 应抛出错误码 ' + expectedCode);
}

void _expect(bool condition, String description) {
  if (!condition) throw StateError('Assertion failed: ' + description);
}
