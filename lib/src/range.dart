class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;
}

class ParsedByteRange {
  const ParsedByteRange.none() : requested = false, range = null;
  const ParsedByteRange.invalid() : requested = true, range = null;
  const ParsedByteRange.valid(this.range) : requested = true;

  final bool requested;
  final ByteRange? range;
}

ParsedByteRange parseSingleByteRange(String? header, int length) {
  if (header == null) return const ParsedByteRange.none();
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || length < 0) return const ParsedByteRange.invalid();
  final first = match.group(1)!;
  final last = match.group(2)!;
  if ((first.isEmpty && last.isEmpty) || length == 0) {
    return const ParsedByteRange.invalid();
  }
  if (first.isEmpty) {
    final suffixLength = int.tryParse(last);
    if (suffixLength == null || suffixLength <= 0) {
      return const ParsedByteRange.invalid();
    }
    final start = suffixLength >= length ? 0 : length - suffixLength;
    return ParsedByteRange.valid(ByteRange(start, length - 1));
  }
  final start = int.tryParse(first);
  final requestedEnd = last.isEmpty ? null : int.tryParse(last);
  if (start == null || start < 0 || start >= length ||
      (last.isNotEmpty && requestedEnd == null)) {
    return const ParsedByteRange.invalid();
  }
  final end = requestedEnd == null || requestedEnd >= length
      ? length - 1
      : requestedEnd;
  if (end < start) return const ParsedByteRange.invalid();
  return ParsedByteRange.valid(ByteRange(start, end));
}

String mimeTypeForMediaPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  return 'video/x-matroska';
}
