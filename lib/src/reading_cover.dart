import 'dart:convert';

/// 上传封面有独立大小限制，正文摘要仍只对应原始文件。
String? parseReadingCover(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length > 350000) {
    throw const FormatException('封面超过限制');
  }
  final bytes = base64Decode(value);
  if (bytes.length > 256 * 1024 || readingCoverMime(bytes) == null) {
    throw const FormatException('封面格式无效');
  }
  return value;
}

String? readingCoverMime(List<int> bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71) {
    return 'image/png';
  }
  if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}
